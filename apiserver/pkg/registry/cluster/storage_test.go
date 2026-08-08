package cluster

import (
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/livenson/talu/apiserver/pkg/apis/tenancy/v1alpha1"
	"github.com/livenson/talu/apiserver/pkg/registry/hr"
)

func testREST() *REST {
	return NewREST(nil, Options{
		ChartName: "talu-cluster", ChartNamespace: "flux-system",
		DefaultsCM: "talu-cluster-defaults", Interval: "5m",
	})
}

func sample() *v1alpha1.ManagedCluster {
	return &v1alpha1.ManagedCluster{
		ObjectMeta: metav1.ObjectMeta{Name: "prod", Namespace: "tenants"},
		Spec: v1alpha1.ManagedClusterSpec{
			ProjectUUID: "uuid-9", KubernetesVersion: "v1.34.1", ControlPlaneReplicas: 2,
			AdminUser: "karl@x", Backup: true,
			Workers: v1alpha1.ManagedClusterWorkers{
				Replicas: 3, Cores: 4, MemoryGiB: 8, Autoscaling: true, Min: 1, Max: 5,
			},
		},
	}
}

func TestRoundTrip(t *testing.T) {
	out, err := fromRelease(testREST().toRelease(sample(), "tenants"))
	if err != nil {
		t.Fatalf("fromRelease: %v", err)
	}
	s := out.Spec
	if s.ProjectUUID != "uuid-9" || s.KubernetesVersion != "v1.34.1" || s.ControlPlaneReplicas != 2 {
		t.Errorf("identity/version lost: %+v", s)
	}
	if s.Workers.Replicas != 3 || s.Workers.Cores != 4 || !s.Workers.Autoscaling ||
		s.Workers.Min != 1 || s.Workers.Max != 5 {
		t.Errorf("workers lost: %+v", s.Workers)
	}
	if s.AdminUser != "karl@x" || !s.Backup {
		t.Errorf("adminUser/backup lost: %q %v", s.AdminUser, s.Backup)
	}
}

// The API takes GiB so a consumer cannot express a unit the chart will not accept; the chart takes a
// quantity string. Getting this mapping wrong renders an unparseable memory value.
func TestMemoryGiBBecomesQuantityString(t *testing.T) {
	u := testREST().toRelease(sample(), "tenants")
	got, _, _ := unstructured.NestedString(u.Object, "spec", "values", "workers", "memory")
	if got != "8Gi" {
		t.Fatalf("workers.memory = %q, want \"8Gi\"", got)
	}
}

// A ManagedCluster and a Tenant release live in the SAME namespace and both carry the ownership
// label, so only the kind label keeps `kubectl get tenant <a-cluster>` from succeeding — and, since
// Delete reads through Get, from destroying a tenant's whole Kubernetes cluster.
func TestKindLabelSeparatesItFromTenant(t *testing.T) {
	l := testREST().toRelease(sample(), "tenants").GetLabels()
	if l[hr.KindLabel] != "managedcluster" {
		t.Fatalf("%s = %q, want \"managedcluster\"", hr.KindLabel, l[hr.KindLabel])
	}
	if l[hr.ManagedByAPILabel] != "true" || l["talu.io/project-uuid"] != "uuid-9" {
		t.Errorf("ownership/join labels wrong: %v", l)
	}
}

// Optional fields must stay ABSENT rather than render as zero values, or the chart would receive
// controlPlane.replicas: 0 and reject it (schema minimum is 1).
func TestUnsetFieldsAreOmitted(t *testing.T) {
	u := testREST().toRelease(&v1alpha1.ManagedCluster{
		ObjectMeta: metav1.ObjectMeta{Name: "min"},
		Spec:       v1alpha1.ManagedClusterSpec{ProjectUUID: "u"},
	}, "tenants")
	vals, _, _ := unstructured.NestedMap(u.Object, "spec", "values")
	for _, k := range []string{"controlPlane", "workers", "wiring", "backup", "kubernetesVersion"} {
		if _, present := vals[k]; present {
			t.Errorf("%q should be omitted when unset, got %v", k, vals[k])
		}
	}
}
