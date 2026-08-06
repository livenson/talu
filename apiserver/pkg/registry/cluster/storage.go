// Package cluster serves ManagedCluster — a tenant's own Kubernetes cluster (KaaS) — as a
// projection over the talu-cluster HelmRelease.
//
// Unlike VirtualMachine, a ManagedCluster lives in the SAME namespace as its backing release: a
// managed cluster is provisioned alongside tenants, not inside a tenant's namespace.
package cluster

import (
	"context"
	"strconv"
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
	ChartName      string
	ChartNamespace string
	DefaultsCM     string
	Interval       string
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

func (r *REST) New() runtime.Object     { return &v1alpha1.ManagedCluster{} }
func (r *REST) NewList() runtime.Object { return &v1alpha1.ManagedClusterList{} }
func (r *REST) NamespaceScoped() bool   { return true }
func (r *REST) GetSingularName() string { return "managedcluster" }
func (r *REST) Destroy()                {}

// kindLabel separates ManagedCluster releases from Tenant releases: both live in the management
// namespace, so the ownership label alone is not enough to tell them apart.
const kindName = "managedcluster"

func nsFrom(ctx context.Context) (string, error) {
	ns, ok := genericapirequest.NamespaceFrom(ctx)
	if !ok || ns == "" {
		return "", errors.NewBadRequest("namespace is required")
	}
	return ns, nil
}

func (r *REST) toRelease(c *v1alpha1.ManagedCluster, ns string) *unstructured.Unstructured {
	values := map[string]interface{}{
		"name":        c.Name,
		"projectUuid": c.Spec.ProjectUUID,
	}
	if c.Spec.KubernetesVersion != "" {
		values["kubernetesVersion"] = c.Spec.KubernetesVersion
	}
	if c.Spec.ControlPlaneReplicas > 0 {
		values["controlPlane"] = map[string]interface{}{"replicas": int64(c.Spec.ControlPlaneReplicas)}
	}
	w := map[string]interface{}{}
	if c.Spec.Workers.Replicas > 0 {
		w["replicas"] = int64(c.Spec.Workers.Replicas)
	}
	if c.Spec.Workers.Cores > 0 {
		w["cores"] = int64(c.Spec.Workers.Cores)
	}
	if c.Spec.Workers.MemoryGiB > 0 {
		// The chart takes a quantity string; this API takes GiB so a consumer cannot express a unit
		// the chart will not accept.
		w["memory"] = strconv.Itoa(int(c.Spec.Workers.MemoryGiB)) + "Gi"
	}
	if c.Spec.Workers.Autoscaling {
		as := map[string]interface{}{"enabled": true}
		if c.Spec.Workers.Min > 0 {
			as["min"] = int64(c.Spec.Workers.Min)
		}
		if c.Spec.Workers.Max > 0 {
			as["max"] = int64(c.Spec.Workers.Max)
		}
		w["autoscaling"] = as
	}
	if len(w) > 0 {
		values["workers"] = w
	}
	if c.Spec.AdminUser != "" {
		values["wiring"] = map[string]interface{}{
			"inTenant": map[string]interface{}{"adminUser": c.Spec.AdminUser},
		}
	}
	if c.Spec.Backup {
		values["backup"] = map[string]interface{}{
			"inTenant": map[string]interface{}{"enabled": true},
		}
	}
	return hr.Release(c.Name, ns, r.opts.ChartName, r.opts.ChartNamespace, r.opts.DefaultsCM,
		r.opts.Interval, c.Spec.ProjectUUID, "", kindName, values, nil)
}

func fromRelease(u *unstructured.Unstructured) (*v1alpha1.ManagedCluster, error) {
	values, _, _ := unstructured.NestedMap(u.Object, "spec", "values")
	c := &v1alpha1.ManagedCluster{}
	c.Name = u.GetName()
	c.Namespace = u.GetNamespace()
	c.UID = u.GetUID()
	c.ResourceVersion = u.GetResourceVersion()
	c.CreationTimestamp = u.GetCreationTimestamp()
	c.Generation = u.GetGeneration()
	if s, ok := values["projectUuid"].(string); ok {
		c.Spec.ProjectUUID = s
	}
	if s, ok := values["kubernetesVersion"].(string); ok {
		c.Spec.KubernetesVersion = s
	}
	if v, _, _ := unstructured.NestedInt64(u.Object, "spec", "values", "controlPlane", "replicas"); v > 0 {
		c.Spec.ControlPlaneReplicas = int32(v)
	}
	if v, _, _ := unstructured.NestedInt64(u.Object, "spec", "values", "workers", "replicas"); v > 0 {
		c.Spec.Workers.Replicas = int32(v)
	}
	if v, _, _ := unstructured.NestedInt64(u.Object, "spec", "values", "workers", "cores"); v > 0 {
		c.Spec.Workers.Cores = int32(v)
	}
	if v, _, _ := unstructured.NestedBool(u.Object, "spec", "values", "workers", "autoscaling", "enabled"); v {
		c.Spec.Workers.Autoscaling = true
	}
	if v, _, _ := unstructured.NestedInt64(u.Object, "spec", "values", "workers", "autoscaling", "min"); v > 0 {
		c.Spec.Workers.Min = int32(v)
	}
	if v, _, _ := unstructured.NestedInt64(u.Object, "spec", "values", "workers", "autoscaling", "max"); v > 0 {
		c.Spec.Workers.Max = int32(v)
	}
	if s, _, _ := unstructured.NestedString(u.Object, "spec", "values", "wiring", "inTenant", "adminUser"); s != "" {
		c.Spec.AdminUser = s
	}
	if v, _, _ := unstructured.NestedBool(u.Object, "spec", "values", "backup", "inTenant", "enabled"); v {
		c.Spec.Backup = true
	}
	if ts := u.GetDeletionTimestamp(); ts != nil {
		c.DeletionTimestamp = ts
	}
	c.Status.Phase, c.Status.Conditions = hr.Phase(u)
	return c, nil
}

func (r *REST) getOwnedCluster(ctx context.Context, ns, name string) (*unstructured.Unstructured, error) {
	// The kind label is what keeps `kubectl get managedcluster acme` from reaching the Tenant acme.
	return hr.GetOwned(ctx, r.client, ns, name, v1alpha1.Resource("managedclusters"), kindName)
}

func (r *REST) Get(ctx context.Context, name string, _ *metav1.GetOptions) (runtime.Object, error) {
	ns, err := nsFrom(ctx)
	if err != nil {
		return nil, err
	}
	u, err := r.getOwnedCluster(ctx, ns, name)
	if err != nil {
		return nil, err
	}
	return fromRelease(u)
}

func (r *REST) selector() string { return hr.Selector(kindName) }

func (r *REST) List(ctx context.Context, _ *metainternalversion.ListOptions) (runtime.Object, error) {
	ns, _ := genericapirequest.NamespaceFrom(ctx)
	l, err := r.client.Resource(hr.GVR).Namespace(ns).
		List(ctx, metav1.ListOptions{LabelSelector: r.selector()})
	if err != nil {
		return nil, err
	}
	out := &v1alpha1.ManagedClusterList{}
	out.ResourceVersion = l.GetResourceVersion()
	for i := range l.Items {
		c, err := fromRelease(&l.Items[i])
		if err != nil {
			continue
		}
		out.Items = append(out.Items, *c)
	}
	return out, nil
}

func (r *REST) Create(ctx context.Context, obj runtime.Object, createValidation rest.ValidateObjectFunc, opts *metav1.CreateOptions) (runtime.Object, error) {
	ns, err := nsFrom(ctx)
	if err != nil {
		return nil, err
	}
	c, ok := obj.(*v1alpha1.ManagedCluster)
	if !ok {
		return nil, errors.NewBadRequest("not a ManagedCluster")
	}
	if createValidation != nil {
		if err := createValidation(ctx, obj); err != nil {
			return nil, err
		}
	}
	if c.Spec.ProjectUUID == "" {
		return nil, errors.NewBadRequest("spec.projectUuid is required")
	}
	created, err := r.client.Resource(hr.GVR).Namespace(ns).
		Create(ctx, r.toRelease(c, ns), metav1.CreateOptions{DryRun: opts.DryRun})
	if err != nil {
		if errors.IsAlreadyExists(err) {
			return nil, errors.NewAlreadyExists(v1alpha1.Resource("managedclusters"), c.Name)
		}
		return nil, err
	}
	return fromRelease(created)
}

func (r *REST) Update(ctx context.Context, name string, objInfo rest.UpdatedObjectInfo,
	createValidation rest.ValidateObjectFunc, updateValidation rest.ValidateObjectUpdateFunc,
	forceAllowCreate bool, opts *metav1.UpdateOptions) (runtime.Object, bool, error) {

	ns, err := nsFrom(ctx)
	if err != nil {
		return nil, false, err
	}
	existing, err := r.getOwnedCluster(ctx, ns, name)
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
	c, ok := newObj.(*v1alpha1.ManagedCluster)
	if !ok {
		return nil, false, errors.NewBadRequest("not a ManagedCluster")
	}
	if updateValidation != nil {
		if err := updateValidation(ctx, c, old); err != nil {
			return nil, false, err
		}
	}
	// Same reasoning as Tenant: the join key is stamped on every rendered object, so changing it
	// under a live cluster would silently re-parent everything it owns.
	if old.Spec.ProjectUUID != "" && c.Spec.ProjectUUID != old.Spec.ProjectUUID {
		return nil, false, errors.NewBadRequest("spec.projectUuid is immutable")
	}
	desired := r.toRelease(c, ns)
	updated := existing.DeepCopy()
	updated.Object["spec"] = desired.Object["spec"]
	labels := updated.GetLabels()
	if labels == nil {
		labels = map[string]string{}
	}
	for k, v := range desired.GetLabels() {
		labels[k] = v
	}
	updated.SetLabels(labels)
	if c.ResourceVersion != "" {
		updated.SetResourceVersion(c.ResourceVersion)
	}
	out, err := r.client.Resource(hr.GVR).Namespace(ns).
		Update(ctx, updated, metav1.UpdateOptions{DryRun: opts.DryRun})
	if err != nil {
		return nil, false, err
	}
	res, err := fromRelease(out)
	return res, false, err
}

func (r *REST) Delete(ctx context.Context, name string, deleteValidation rest.ValidateObjectFunc, opts *metav1.DeleteOptions) (runtime.Object, bool, error) {
	ns, err := nsFrom(ctx)
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
	if err := r.client.Resource(hr.GVR).Namespace(ns).Delete(ctx, name, *opts); err != nil {
		return nil, false, err
	}
	return existing, true, nil
}

func (r *REST) Watch(ctx context.Context, options *metainternalversion.ListOptions) (watch.Interface, error) {
	ns, _ := genericapirequest.NamespaceFrom(ctx)
	o := metav1.ListOptions{LabelSelector: r.selector(), AllowWatchBookmarks: options.AllowWatchBookmarks}
	if options.ResourceVersion != "" {
		o.ResourceVersion = options.ResourceVersion
	}
	if options.TimeoutSeconds != nil {
		o.TimeoutSeconds = options.TimeoutSeconds
	}
	w, err := r.client.Resource(hr.GVR).Namespace(ns).Watch(ctx, o)
	if err != nil {
		return nil, err
	}
	return watch.Filter(w, func(e watch.Event) (watch.Event, bool) {
		u, ok := e.Object.(*unstructured.Unstructured)
		if !ok {
			return e, true
		}
		c, err := fromRelease(u)
		if err != nil {
			return e, false
		}
		e.Object = c
		return e, true
	}), nil
}

func (r *REST) ConvertToTable(_ context.Context, obj runtime.Object, _ runtime.Object) (*metav1.Table, error) {
	t := &metav1.Table{ColumnDefinitions: []metav1.TableColumnDefinition{
		{Name: "Name", Type: "string", Format: "name"},
		{Name: "Project", Type: "string"},
		{Name: "Version", Type: "string"},
		{Name: "Workers", Type: "integer"},
		{Name: "Phase", Type: "string"},
		{Name: "Age", Type: "string"},
	}}
	row := func(x *v1alpha1.ManagedCluster) metav1.TableRow {
		return metav1.TableRow{
			Cells: []interface{}{x.Name, x.Spec.ProjectUUID, x.Spec.KubernetesVersion,
				x.Spec.Workers.Replicas, x.Status.Phase,
				duration.HumanDuration(time.Since(x.CreationTimestamp.Time))},
			Object: runtime.RawExtension{Object: x},
		}
	}
	switch v := obj.(type) {
	case *v1alpha1.ManagedCluster:
		t.Rows = append(t.Rows, row(v))
	case *v1alpha1.ManagedClusterList:
		t.ResourceVersion = v.ResourceVersion
		for i := range v.Items {
			t.Rows = append(t.Rows, row(&v.Items[i]))
		}
	}
	return t, nil
}
