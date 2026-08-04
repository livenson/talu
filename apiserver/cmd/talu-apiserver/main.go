// talu-apiserver — serves tenancy.talu.io/v1alpha1 as a projection over Flux HelmReleases.
// Design + the failure modes this must be operated with: docs/architecture/adr-api-layer.md.
package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
	genericapiserver "k8s.io/apiserver/pkg/server"
	genericoptions "k8s.io/apiserver/pkg/server/options"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/rest"
	"k8s.io/component-base/cli"

	tenantstore "github.com/livenson/talu/apiserver/pkg/registry/tenant"
	taluserver "github.com/livenson/talu/apiserver/pkg/server"
)

type options struct {
	SecureServing  *genericoptions.SecureServingOptionsWithLoopback
	Authentication *genericoptions.DelegatingAuthenticationOptions
	Authorization  *genericoptions.DelegatingAuthorizationOptions
	Tenant         tenantstore.Options
}

func newOptions() *options {
	s := genericoptions.NewSecureServingOptions().WithLoopback()
	s.BindPort = 6443
	return &options{
		SecureServing:  s,
		Authentication: genericoptions.NewDelegatingAuthenticationOptions(),
		Authorization:  genericoptions.NewDelegatingAuthorizationOptions(),
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
	if err := o.SecureServing.ApplyTo(&c.Config.SecureServing, &c.Config.LoopbackClientConfig); err != nil {
		return nil, err
	}
	if err := o.Authentication.ApplyTo(&c.Config.Authentication, c.SecureServing, nil); err != nil {
		return nil, err
	}
	if err := o.Authorization.ApplyTo(&c.Config.Authorization); err != nil {
		return nil, err
	}
	// In-cluster credentials: this server talks to kube-apiserver as its own ServiceAccount, and RBAC
	// on that SA is what bounds it — it can only touch HelmReleases.
	rc, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("in-cluster config: %w", err)
	}
	dc, err := dynamic.NewForConfig(rc)
	if err != nil {
		return nil, err
	}
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
	fs.StringVar(&o.Tenant.ChartName, "tenant-chart", o.Tenant.ChartName, "OCIRepository name of the talu-tenant chart.")
	fs.StringVar(&o.Tenant.ChartNamespace, "tenant-chart-namespace", o.Tenant.ChartNamespace, "Namespace of that OCIRepository.")
	fs.StringVar(&o.Tenant.DefaultsCM, "tenant-defaults-configmap", o.Tenant.DefaultsCM, "ConfigMap holding the site's operator-owned tenant values.")
	fs.StringVar(&o.Tenant.Interval, "helmrelease-interval", o.Tenant.Interval, "spec.interval on generated HelmReleases.")

	os.Exit(cli.Run(cmd))
}
