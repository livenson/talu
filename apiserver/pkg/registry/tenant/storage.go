// Package tenant implements the Tenant REST storage as a projection over Flux HelmReleases.
//
// There is deliberately NO storage of our own: a Tenant IS the HelmRelease that renders it, viewed
// through Talu's schema (docs/architecture/adr-api-layer.md §2). That is what buys the break-glass —
// deleting the APIService restores full cluster function because the real state is untouched and Flux
// keeps reconciling.
package tenant

import (
	"context"
	"fmt"

	"k8s.io/apimachinery/pkg/api/errors"
	metainternalversion "k8s.io/apimachinery/pkg/apis/meta/internalversion"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/apiserver/pkg/registry/rest"
	genericapirequest "k8s.io/apiserver/pkg/endpoints/request"
	"k8s.io/client-go/dynamic"

	"github.com/livenson/talu/apiserver/pkg/apis/tenancy/v1alpha1"
)

// helmReleaseGVR is the object we project onto. Using the dynamic client rather than Flux's Go types
// keeps Flux out of this module's dependency graph — it is an implementation detail, not a contract.
var helmReleaseGVR = schema.GroupVersionResource{
	Group: "helm.toolkit.fluxcd.io", Version: "v2", Resource: "helmreleases",
}

// Options a site sets once; they decide which chart a Tenant renders.
type Options struct {
	ChartName      string // OCIRepository name, e.g. talu-tenant
	ChartNamespace string // where that OCIRepository lives, e.g. flux-system
	DefaultsCM     string // ConfigMap holding the site's operator-owned values
	Interval       string // HelmRelease spec.interval
}

type REST struct {
	client dynamic.Interface
	opts   Options
	rest.TableConvertor
}

var (
	_ rest.Storage               = &REST{}
	_ rest.Scoper                = &REST{}
	_ rest.Getter                = &REST{}
	_ rest.Lister                = &REST{}
	_ rest.Creater               = &REST{}
	_ rest.GracefulDeleter       = &REST{}
	_ rest.SingularNameProvider  = &REST{}
)

func NewREST(c dynamic.Interface, o Options) *REST {
	return &REST{
		client: c,
		opts:   o,
		TableConvertor: rest.NewDefaultTableConvertor(v1alpha1.Resource("tenants")),
	}
}

func (r *REST) New() runtime.Object                        { return &v1alpha1.Tenant{} }
func (r *REST) NewList() runtime.Object                    { return &v1alpha1.TenantList{} }
func (r *REST) NamespaceScoped() bool                      { return true }
func (r *REST) GetSingularName() string                    { return "tenant" }
func (r *REST) Destroy()                                   {}

func namespaceFrom(ctx context.Context) (string, error) {
	ns, ok := genericapirequest.NamespaceFrom(ctx)
	if !ok || ns == "" {
		return "", errors.NewBadRequest("namespace is required")
	}
	return ns, nil
}

// toHelmRelease renders a Tenant into the HelmRelease that backs it. The chart values are the
// consumer-owned half of the talu-tenant schema; the operator-owned half is merged by Flux from the
// site's defaults ConfigMap BEFORE these values (ADR §4).
func (r *REST) toHelmRelease(t *v1alpha1.Tenant, ns string) *unstructured.Unstructured {
	values := map[string]interface{}{
		"projectUuid": t.Spec.ProjectUUID,
		"slug":        t.Name,
	}
	if len(t.Spec.Members) > 0 {
		m := make([]interface{}, 0, len(t.Spec.Members))
		for _, s := range t.Spec.Members {
			m = append(m, s)
		}
		values["allowedUsers"] = m
	}
	if len(t.Spec.Quota) > 0 {
		q := map[string]interface{}{}
		for k, v := range t.Spec.Quota {
			q[k] = v
		}
		values["resourceQuota"] = q
	}
	if t.Spec.Dashboards {
		values["dashboards"] = map[string]interface{}{"enabled": true}
	}
	if t.Spec.NetworkBaseline {
		values["networkBaseline"] = map[string]interface{}{"enabled": true}
	}

	valuesFrom := []interface{}{
		map[string]interface{}{
			"kind": "ConfigMap", "name": r.opts.DefaultsCM,
			"valuesKey": "values.yaml", "optional": true,
		},
	}

	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "helm.toolkit.fluxcd.io/v2",
		"kind":       "HelmRelease",
		"metadata": map[string]interface{}{
			"name":      t.Name,
			"namespace": ns,
			"labels": map[string]interface{}{
				"app.kubernetes.io/part-of": "talu",
				"talu.io/tenant":            t.Name,
				// The join key, so the backing objects are discoverable exactly as before.
				"talu.io/project-uuid": t.Spec.ProjectUUID,
				// Marks this release as owned by the typed API rather than hand-written.
				"talu.io/managed-by-api": "true",
			},
		},
		"spec": map[string]interface{}{
			"interval":    r.opts.Interval,
			"releaseName": t.Name,
			"chartRef": map[string]interface{}{
				"kind": "OCIRepository", "name": r.opts.ChartName, "namespace": r.opts.ChartNamespace,
			},
			"valuesFrom": valuesFrom,
			"values":     values,
		},
	}}
}

// fromHelmRelease projects a HelmRelease back into the Tenant view.
func fromHelmRelease(u *unstructured.Unstructured) (*v1alpha1.Tenant, error) {
	t := &v1alpha1.Tenant{}
	t.Name = u.GetName()
	t.Namespace = u.GetNamespace()
	t.UID = u.GetUID()
	t.ResourceVersion = u.GetResourceVersion()
	t.CreationTimestamp = u.GetCreationTimestamp()
	t.Generation = u.GetGeneration()

	values, _, _ := unstructured.NestedMap(u.Object, "spec", "values")
	if v, ok := values["projectUuid"].(string); ok {
		t.Spec.ProjectUUID = v
	}
	if v, ok := values["allowedUsers"].([]interface{}); ok {
		for _, m := range v {
			if s, ok := m.(string); ok {
				t.Spec.Members = append(t.Spec.Members, s)
			}
		}
	}
	if v, ok := values["resourceQuota"].(map[string]interface{}); ok {
		t.Spec.Quota = map[string]string{}
		for k, q := range v {
			t.Spec.Quota[k] = fmt.Sprintf("%v", q)
		}
	}
	if v, _, _ := unstructured.NestedBool(u.Object, "spec", "values", "dashboards", "enabled"); v {
		t.Spec.Dashboards = true
	}
	if v, _, _ := unstructured.NestedBool(u.Object, "spec", "values", "networkBaseline", "enabled"); v {
		t.Spec.NetworkBaseline = true
	}

	// Status rollup. The HelmRelease's Ready condition is "chart applied"; a fuller rollup (every VM
	// Running) rides on the chart's healthCheckExprs and lands here unchanged once wired.
	conds, _, _ := unstructured.NestedSlice(u.Object, "status", "conditions")
	t.Status.Phase = "Pending"
	for _, c := range conds {
		cm, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		cond := metav1.Condition{}
		cond.Type, _ = cm["type"].(string)
		s, _ := cm["status"].(string)
		cond.Status = metav1.ConditionStatus(s)
		cond.Reason, _ = cm["reason"].(string)
		cond.Message, _ = cm["message"].(string)
		if cond.Reason == "" {
			cond.Reason = "Unknown"
		}
		t.Status.Conditions = append(t.Status.Conditions, cond)
		if cond.Type == "Ready" {
			switch cond.Status {
			case metav1.ConditionTrue:
				t.Status.Phase = "Ready"
			case metav1.ConditionFalse:
				t.Status.Phase = "Degraded"
			default:
				t.Status.Phase = "Provisioning"
			}
		}
	}
	return t, nil
}

func (r *REST) Get(ctx context.Context, name string, _ *metav1.GetOptions) (runtime.Object, error) {
	ns, err := namespaceFrom(ctx)
	if err != nil {
		return nil, err
	}
	u, err := r.client.Resource(helmReleaseGVR).Namespace(ns).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		if errors.IsNotFound(err) {
			return nil, errors.NewNotFound(v1alpha1.Resource("tenants"), name)
		}
		return nil, err
	}
	return fromHelmRelease(u)
}

func (r *REST) List(ctx context.Context, _ *metainternalversion.ListOptions) (runtime.Object, error) {
	ns, _ := genericapirequest.NamespaceFrom(ctx)
	l, err := r.client.Resource(helmReleaseGVR).Namespace(ns).List(ctx, metav1.ListOptions{
		// Only releases this API owns — a hand-written HelmRelease is not a Tenant.
		LabelSelector: "talu.io/managed-by-api=true",
	})
	if err != nil {
		return nil, err
	}
	out := &v1alpha1.TenantList{}
	out.ResourceVersion = l.GetResourceVersion()
	for i := range l.Items {
		t, err := fromHelmRelease(&l.Items[i])
		if err != nil {
			continue
		}
		out.Items = append(out.Items, *t)
	}
	return out, nil
}

func (r *REST) Create(ctx context.Context, obj runtime.Object, createValidation rest.ValidateObjectFunc, opts *metav1.CreateOptions) (runtime.Object, error) {
	ns, err := namespaceFrom(ctx)
	if err != nil {
		return nil, err
	}
	t, ok := obj.(*v1alpha1.Tenant)
	if !ok {
		return nil, errors.NewBadRequest("not a Tenant")
	}
	if createValidation != nil {
		if err := createValidation(ctx, obj); err != nil {
			return nil, err
		}
	}
	if t.Spec.ProjectUUID == "" {
		return nil, errors.NewBadRequest("spec.projectUuid is required")
	}
	created, err := r.client.Resource(helmReleaseGVR).Namespace(ns).
		Create(ctx, r.toHelmRelease(t, ns), metav1.CreateOptions{DryRun: opts.DryRun})
	if err != nil {
		if errors.IsAlreadyExists(err) {
			return nil, errors.NewAlreadyExists(v1alpha1.Resource("tenants"), t.Name)
		}
		return nil, err
	}
	return fromHelmRelease(created)
}

func (r *REST) Delete(ctx context.Context, name string, deleteValidation rest.ValidateObjectFunc, opts *metav1.DeleteOptions) (runtime.Object, bool, error) {
	ns, err := namespaceFrom(ctx)
	if err != nil {
		return nil, false, err
	}
	existing, err := r.Get(ctx, name, &metav1.GetOptions{})
	if err != nil {
		return nil, false, err
	}
	if deleteValidation != nil {
		if err := deleteValidation(ctx, existing); err != nil {
			return nil, false, err
		}
	}
	if err := r.client.Resource(helmReleaseGVR).Namespace(ns).Delete(ctx, name, *opts); err != nil {
		return nil, false, err
	}
	return existing, true, nil
}

// Watch is not implemented yet: clients poll. Wiring it means translating a HelmRelease watch stream
// through fromHelmRelease, which is mechanical but wants its own tests.
func (r *REST) Watch(ctx context.Context, _ *metainternalversion.ListOptions) (watch.Interface, error) {
	return nil, errors.NewMethodNotSupported(v1alpha1.Resource("tenants"), "watch")
}
