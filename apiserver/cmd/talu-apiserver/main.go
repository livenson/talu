// talu-apiserver — serves tenancy.talu.io/v1alpha1 as a projection over Flux HelmReleases.
// Design + the failure modes this must be operated with: docs/architecture/adr-api-layer.md.
package main

import (
	"fmt"
	"os"
	"time"

	"github.com/spf13/cobra"
	genericapiserver "k8s.io/apiserver/pkg/server"
	genericoptions "k8s.io/apiserver/pkg/server/options"
	"k8s.io/apiserver/pkg/util/compatibility"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/component-base/cli"

	tenantstore "github.com/livenson/talu/apiserver/pkg/registry/tenant"
	taluserver "github.com/livenson/talu/apiserver/pkg/server"
)

type options struct {
	SecureServing  *genericoptions.SecureServingOptionsWithLoopback
	Authentication *genericoptions.DelegatingAuthenticationOptions
	Authorization  *genericoptions.DelegatingAuthorizationOptions
	// Audit matters here: this API mediates tenant creation, so "who created/deleted which tenant"
	// must be answerable. components/platform/api/deployment.yaml passes --audit-log-path.
	Audit  *genericoptions.AuditOptions
	Tenant tenantstore.Options
	// Kubeconfig is empty in production — the server runs in-cluster and uses its ServiceAccount.
	// Set it to drive the server from outside the cluster (development, or probing the API before
	// committing to an in-cluster image).
	Kubeconfig string
}

func newOptions() *options {
	s := genericoptions.NewSecureServingOptions().WithLoopback()
	s.BindPort = 6443
	return &options{
		SecureServing:  s,
		Authentication: genericoptions.NewDelegatingAuthenticationOptions(),
		Authorization:  genericoptions.NewDelegatingAuthorizationOptions(),
		Audit:          genericoptions.NewAuditOptions(),
		Tenant: tenantstore.Options{
			ChartName: "talu-tenant", ChartNamespace: "flux-system",
			DefaultsCM: "talu-tenant-defaults", Interval: "5m",
		},
	}
}

func (o *options) config() (*taluserver.Config, error) {
	if err := o.SecureServing.MaybeDefaultWithSelfSignedCerts("localhost", nil, nil); err != nil {
		return nil, fmt.Errorf("self-signed cert: %w", err)
	}
	c := genericapiserver.NewRecommendedConfig(taluserver.Codecs)
	// Required since apiserver 0.31: Config.Complete() dereferences EffectiveVersion. The canonical
	// wiring sets it via ServerRunOptions.ApplyTo, which this server does not use (it needs none of
	// the other universal flags), so set it directly.
	c.EffectiveVersion = compatibility.DefaultBuildEffectiveVersion()
	if err := o.SecureServing.ApplyTo(&c.Config.SecureServing, &c.Config.LoopbackClientConfig); err != nil {
		return nil, err
	}
	if err := o.Authentication.ApplyTo(&c.Config.Authentication, c.SecureServing, nil); err != nil {
		return nil, err
	}
	if err := o.Authorization.ApplyTo(&c.Config.Authorization); err != nil {
		return nil, err
	}
	if err := o.Audit.ApplyTo(&c.Config); err != nil {
		return nil, err
	}
	// In-cluster credentials: this server talks to kube-apiserver as its own ServiceAccount, and RBAC
	// on that SA is what bounds it — it can only touch HelmReleases.
	rc, err := clientConfig(o.Kubeconfig)
	if err != nil {
		return nil, err
	}
	dc, err := dynamic.NewForConfig(rc)
	if err != nil {
		return nil, err
	}
	// RecommendedConfig.Complete() dereferences the informer factory, so it must be set even though
	// this server watches nothing of its own — delegated authn/authz use it for the
	// extension-apiserver-authentication ConfigMap and for SubjectAccessReview caching.
	kc, err := kubernetes.NewForConfig(rc)
	if err != nil {
		return nil, err
	}
	c.SharedInformerFactory = informers.NewSharedInformerFactory(kc, 10*time.Minute)
	return &taluserver.Config{Generic: c, Dynamic: dc, Tenant: o.Tenant}, nil
}

func main() {
	o := newOptions()
	cmd := &cobra.Command{
		Use:   "talu-apiserver",
		Short: "Serves tenancy.talu.io as a view over Flux HelmReleases",
		RunE: func(cmd *cobra.Command, _ []string) error {
			cfg, err := o.config()
			if err != nil {
				return err
			}
			srv, err := cfg.New()
			if err != nil {
				return err
			}
			return srv.GenericAPIServer.PrepareRun().RunWithContext(cmd.Context())
		},
	}
	fs := cmd.Flags()
	o.SecureServing.AddFlags(fs)
	o.Authentication.AddFlags(fs)
	o.Authorization.AddFlags(fs)
	o.Audit.AddFlags(fs)
	fs.StringVar(&o.Tenant.ChartName, "tenant-chart", o.Tenant.ChartName, "OCIRepository name of the talu-tenant chart.")
	fs.StringVar(&o.Tenant.ChartNamespace, "tenant-chart-namespace", o.Tenant.ChartNamespace, "Namespace of that OCIRepository.")
	fs.StringVar(&o.Tenant.DefaultsCM, "tenant-defaults-configmap", o.Tenant.DefaultsCM, "ConfigMap holding the site's operator-owned tenant values.")
	fs.StringVar(&o.Tenant.Interval, "helmrelease-interval", o.Tenant.Interval, "spec.interval on generated HelmReleases.")
	fs.StringVar(&o.Kubeconfig, "kubeconfig", o.Kubeconfig, "Path to a kubeconfig for reaching the management API. Empty (the default) uses the in-cluster ServiceAccount.")

	os.Exit(cli.Run(cmd))
}

// clientConfig prefers an explicit kubeconfig, falling back to the in-cluster ServiceAccount.
func clientConfig(kubeconfig string) (*rest.Config, error) {
	if kubeconfig != "" {
		cfg, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			return nil, fmt.Errorf("kubeconfig %q: %w", kubeconfig, err)
		}
		return cfg, nil
	}
	cfg, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("in-cluster config (pass --kubeconfig to run outside a pod): %w", err)
	}
	return cfg, nil
}
