// Package vm serves VirtualMachine as a projection over the talu-vm HelmRelease.
//
// Namespace mapping is the wrinkle: a VirtualMachine lives in the TENANT's namespace (so a tenant
// admin's RBAC scopes naturally), while its backing HelmRelease lives in the management namespace
// next to the Tenant's, named "<tenant>-<vm>" — the same name the tenancy role generates, so the
// typed API and the Git path produce identical objects.
package vm

import (
	"context"
	"fmt"
	"strings"
	"time"

	"k8s.io/apimachinery/pkg/api/errors"
	metainternalversion "k8s.io/apimachinery/pkg/apis/meta/internalversion"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/util/duration"
	"k8s.io/apimachinery/pkg/watch"
	genericapirequest "k8s.io/apiserver/pkg/endpoints/request"
	"k8s.io/apiserver/pkg/registry/rest"
	"k8s.io/client-go/dynamic"

	"github.com/livenson/talu/apiserver/pkg/apis/tenancy/v1alpha1"
	"github.com/livenson/talu/apiserver/pkg/registry/hr"
)

type Options struct {
	ChartName        string
	ChartNamespace   string
	DefaultsCM       string
	Interval         string
	ReleaseNamespace string // where the HelmReleases live (the management namespace)
	CASecretName     string // ConfigMap holding the Pomerium SSH User CA (injected per VM)
}

type REST struct {
	client dynamic.Interface
	opts   Options
}

var (
	_ rest.Storage              = &REST{}
	_ rest.Scoper               = &REST{}
	_ rest.Getter               = &REST{}
	_ rest.Lister               = &REST{}
	_ rest.Creater              = &REST{}
	_ rest.Updater              = &REST{}
	_ rest.GracefulDeleter      = &REST{}
	_ rest.Watcher              = &REST{}
	_ rest.TableConvertor       = &REST{}
	_ rest.SingularNameProvider = &REST{}
)

func NewREST(c dynamic.Interface, o Options) *REST { return &REST{client: c, opts: o} }

func (r *REST) New() runtime.Object     { return &v1alpha1.VirtualMachine{} }
func (r *REST) NewList() runtime.Object { return &v1alpha1.VirtualMachineList{} }
func (r *REST) NamespaceScoped() bool   { return true }
func (r *REST) GetSingularName() string { return "virtualmachine" }
func (r *REST) Destroy()                {}

// releaseName is how a tenant namespace + VM name become one HelmRelease name.
func releaseName(tenant, name string) string { return tenant + "-" + name }

func tenantFrom(ctx context.Context) (string, error) {
	ns, ok := genericapirequest.NamespaceFrom(ctx)
	if !ok || ns == "" {
		return "", errors.NewBadRequest("namespace is required")
	}
	return ns, nil
}

func (r *REST) toRelease(v *v1alpha1.VirtualMachine, tenant string) *unstructured.Unstructured {
	values := map[string]interface{}{
		"slug": tenant,
		"name": v.Name,
	}
	if v.Spec.Size != "" {
		values["size"] = v.Spec.Size
	}
	if v.Spec.Principal != "" {
		values["principal"] = v.Spec.Principal
	}
	if v.Spec.RootDiskSize != "" {
		values["rootDiskSize"] = v.Spec.RootDiskSize
	}
	if len(v.Spec.SecurityGroups) > 0 {
		sgs := make([]interface{}, 0, len(v.Spec.SecurityGroups))
		for _, s := range v.Spec.SecurityGroups {
			sgs = append(sgs, s)
		}
		values["securityGroups"] = sgs
	}
	// projectUuid and allowedUsers are the TENANT's, injected here exactly as the tenancy role does
	// from tenant.yaml — a VM never restates its tenant's identity.
	values["projectUuid"] = v.Annotations["talu.io/project-uuid"]
	if au := v.Annotations["talu.io/allowed-users"]; au != "" {
		list := []interface{}{}
		for _, u := range strings.Split(au, ",") {
			if u != "" {
				list = append(list, u)
			}
		}
		values["allowedUsers"] = list
	}

	return hr.Release(releaseName(tenant, v.Name), r.opts.ReleaseNamespace,
		r.opts.ChartName, r.opts.ChartNamespace, r.opts.DefaultsCM, r.opts.Interval,
		v.Annotations["talu.io/project-uuid"], tenant, values,
		map[string]string{"talu.io/vm": v.Name},
		// The talu-vm chart REQUIRES a non-empty sshUserCaPubKey (lab-notes: tenancy hard-depends on
		// the SSH CA). The tenancy role injects it live from this ConfigMap so a rotation needs no
		// edit; the typed API has to do the same or every VM it creates sits Ready=False.
		map[string]interface{}{
			"kind": "ConfigMap", "name": r.opts.CASecretName,
			"valuesKey": "user_ca.pub", "targetPath": "sshUserCaPubKey",
		})
}

func fromRelease(u *unstructured.Unstructured) (*v1alpha1.VirtualMachine, error) {
	values, _, _ := unstructured.NestedMap(u.Object, "spec", "values")
	name, _ := values["name"].(string)
	tenant, _ := values["slug"].(string)
	if name == "" || tenant == "" {
		return nil, fmt.Errorf("release %s/%s is not a Talu VM", u.GetNamespace(), u.GetName())
	}
	v := &v1alpha1.VirtualMachine{}
	v.Name = name
	v.Namespace = tenant
	v.UID = u.GetUID()
	v.ResourceVersion = u.GetResourceVersion()
	v.CreationTimestamp = u.GetCreationTimestamp()
	v.Generation = u.GetGeneration()
	if pu, ok := values["projectUuid"].(string); ok && pu != "" {
		v.Annotations = map[string]string{"talu.io/project-uuid": pu}
	}
	if s, ok := values["size"].(string); ok {
		v.Spec.Size = s
	}
	if s, ok := values["principal"].(string); ok {
		v.Spec.Principal = s
	}
	if s, ok := values["rootDiskSize"].(string); ok {
		v.Spec.RootDiskSize = s
	}
	if sg, ok := values["securityGroups"].([]interface{}); ok {
		for _, x := range sg {
			if s, ok := x.(string); ok {
				v.Spec.SecurityGroups = append(v.Spec.SecurityGroups, s)
			}
		}
	}
	if ts := u.GetDeletionTimestamp(); ts != nil {
		v.DeletionTimestamp = ts
	}
	v.Status.Phase, v.Status.Conditions = hr.Phase(u)
	return v, nil
}

func (r *REST) Get(ctx context.Context, name string, _ *metav1.GetOptions) (runtime.Object, error) {
	tenant, err := tenantFrom(ctx)
	if err != nil {
		return nil, err
	}
	u, err := hr.GetOwned(ctx, r.client, r.opts.ReleaseNamespace, releaseName(tenant, name),
		v1alpha1.Resource("virtualmachines"))
	if err != nil {
		return nil, err
	}
	return fromRelease(u)
}

func (r *REST) listReleases(ctx context.Context, tenant string) (*unstructured.UnstructuredList, error) {
	sel := hr.ManagedByAPILabel + "=true," + hr.TenantLabel + "=" + tenant + ",talu.io/vm"
	return r.client.Resource(hr.GVR).Namespace(r.opts.ReleaseNamespace).
		List(ctx, metav1.ListOptions{LabelSelector: sel})
}

func (r *REST) List(ctx context.Context, _ *metainternalversion.ListOptions) (runtime.Object, error) {
	tenant, err := tenantFrom(ctx)
	if err != nil {
		return nil, err
	}
	l, err := r.listReleases(ctx, tenant)
	if err != nil {
		return nil, err
	}
	out := &v1alpha1.VirtualMachineList{}
	out.ResourceVersion = l.GetResourceVersion()
	for i := range l.Items {
		v, err := fromRelease(&l.Items[i])
		if err != nil {
			continue
		}
		out.Items = append(out.Items, *v)
	}
	return out, nil
}

func (r *REST) Create(ctx context.Context, obj runtime.Object, createValidation rest.ValidateObjectFunc, opts *metav1.CreateOptions) (runtime.Object, error) {
	tenant, err := tenantFrom(ctx)
	if err != nil {
		return nil, err
	}
	v, ok := obj.(*v1alpha1.VirtualMachine)
	if !ok {
		return nil, errors.NewBadRequest("not a VirtualMachine")
	}
	if createValidation != nil {
		if err := createValidation(ctx, obj); err != nil {
			return nil, err
		}
	}
	// The VM inherits its tenant's join key. Reading it from the Tenant's own release keeps a single
	// source of truth: a VM cannot claim to belong to a project its tenant does not.
	tu, err := hr.GetOwned(ctx, r.client, r.opts.ReleaseNamespace, tenant, v1alpha1.Resource("tenants"))
	if err != nil {
		return nil, errors.NewBadRequest(fmt.Sprintf("no Tenant %q owns this namespace: %v", tenant, err))
	}
	pu, _, _ := unstructured.NestedString(tu.Object, "spec", "values", "projectUuid")
	if v.Annotations == nil {
		v.Annotations = map[string]string{}
	}
	v.Annotations["talu.io/project-uuid"] = pu
	// The tenant's member list drives the VM's ssh Service annotation, which the Pomerium route
	// renderer reads. Taken from the Tenant, never restated per VM.
	if au, _, _ := unstructured.NestedSlice(tu.Object, "spec", "values", "allowedUsers"); len(au) > 0 {
		users := make([]string, 0, len(au))
		for _, x := range au {
			if s, ok := x.(string); ok {
				users = append(users, s)
			}
		}
		v.Annotations["talu.io/allowed-users"] = strings.Join(users, ",")
	}

	created, err := r.client.Resource(hr.GVR).Namespace(r.opts.ReleaseNamespace).
		Create(ctx, r.toRelease(v, tenant), metav1.CreateOptions{DryRun: opts.DryRun})
	if err != nil {
		if errors.IsAlreadyExists(err) {
			return nil, errors.NewAlreadyExists(v1alpha1.Resource("virtualmachines"), v.Name)
		}
		return nil, err
	}
	return fromRelease(created)
}

func (r *REST) Update(ctx context.Context, name string, objInfo rest.UpdatedObjectInfo,
	createValidation rest.ValidateObjectFunc, updateValidation rest.ValidateObjectUpdateFunc,
	forceAllowCreate bool, opts *metav1.UpdateOptions) (runtime.Object, bool, error) {

	tenant, err := tenantFrom(ctx)
	if err != nil {
		return nil, false, err
	}
	existing, err := hr.GetOwned(ctx, r.client, r.opts.ReleaseNamespace, releaseName(tenant, name),
		v1alpha1.Resource("virtualmachines"))
	if err != nil {
		return nil, false, err
	}
	old, err := fromRelease(existing)
	if err != nil {
		return nil, false, err
	}
	newObj, err := objInfo.UpdatedObject(ctx, old)
	if err != nil {
		return nil, false, err
	}
	v, ok := newObj.(*v1alpha1.VirtualMachine)
	if !ok {
		return nil, false, errors.NewBadRequest("not a VirtualMachine")
	}
	if updateValidation != nil {
		if err := updateValidation(ctx, v, old); err != nil {
			return nil, false, err
		}
	}
	// Carry the tenant's join key forward; it is not the VM's to change.
	if v.Annotations == nil {
		v.Annotations = map[string]string{}
	}
	v.Annotations["talu.io/project-uuid"] = old.Annotations["talu.io/project-uuid"]

	desired := r.toRelease(v, tenant)
	updated := existing.DeepCopy()
	updated.Object["spec"] = desired.Object["spec"]
	labels := updated.GetLabels()
	if labels == nil {
		labels = map[string]string{}
	}
	for k, val := range desired.GetLabels() {
		labels[k] = val
	}
	updated.SetLabels(labels)
	if v.ResourceVersion != "" {
		updated.SetResourceVersion(v.ResourceVersion)
	}
	out, err := r.client.Resource(hr.GVR).Namespace(r.opts.ReleaseNamespace).
		Update(ctx, updated, metav1.UpdateOptions{DryRun: opts.DryRun})
	if err != nil {
		return nil, false, err
	}
	res, err := fromRelease(out)
	return res, false, err
}

func (r *REST) Delete(ctx context.Context, name string, deleteValidation rest.ValidateObjectFunc, opts *metav1.DeleteOptions) (runtime.Object, bool, error) {
	tenant, err := tenantFrom(ctx)
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
	if err := r.client.Resource(hr.GVR).Namespace(r.opts.ReleaseNamespace).
		Delete(ctx, releaseName(tenant, name), *opts); err != nil {
		return nil, false, err
	}
	return existing, true, nil
}

func (r *REST) Watch(ctx context.Context, options *metainternalversion.ListOptions) (watch.Interface, error) {
	tenant, err := tenantFrom(ctx)
	if err != nil {
		return nil, err
	}
	sel := hr.ManagedByAPILabel + "=true," + hr.TenantLabel + "=" + tenant + ",talu.io/vm"
	o := metav1.ListOptions{LabelSelector: sel, AllowWatchBookmarks: options.AllowWatchBookmarks}
	if options.ResourceVersion != "" {
		o.ResourceVersion = options.ResourceVersion
	}
	if options.TimeoutSeconds != nil {
		o.TimeoutSeconds = options.TimeoutSeconds
	}
	w, err := r.client.Resource(hr.GVR).Namespace(r.opts.ReleaseNamespace).Watch(ctx, o)
	if err != nil {
		return nil, err
	}
	return watch.Filter(w, func(e watch.Event) (watch.Event, bool) {
		u, ok := e.Object.(*unstructured.Unstructured)
		if !ok {
			return e, true
		}
		v, err := fromRelease(u)
		if err != nil {
			return e, false
		}
		e.Object = v
		return e, true
	}), nil
}

func (r *REST) ConvertToTable(_ context.Context, obj runtime.Object, _ runtime.Object) (*metav1.Table, error) {
	t := &metav1.Table{ColumnDefinitions: []metav1.TableColumnDefinition{
		{Name: "Name", Type: "string", Format: "name"},
		{Name: "Size", Type: "string", Description: "Named size (a VirtualMachineClusterInstancetype)."},
		{Name: "Principal", Type: "string", Description: "Guest user / SSH cert principal."},
		{Name: "Phase", Type: "string"},
		{Name: "Age", Type: "string"},
	}}
	row := func(x *v1alpha1.VirtualMachine) metav1.TableRow {
		return metav1.TableRow{
			Cells: []interface{}{x.Name, x.Spec.Size, x.Spec.Principal, x.Status.Phase,
				duration.HumanDuration(time.Since(x.CreationTimestamp.Time))},
			Object: runtime.RawExtension{Object: x},
		}
	}
	switch v := obj.(type) {
	case *v1alpha1.VirtualMachine:
		t.Rows = append(t.Rows, row(v))
	case *v1alpha1.VirtualMachineList:
		t.ResourceVersion = v.ResourceVersion
		for i := range v.Items {
			t.Rows = append(t.Rows, row(&v.Items[i]))
		}
	}
	return t, nil
}
