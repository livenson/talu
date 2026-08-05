package tenant

import (
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"

	"github.com/livenson/talu/apiserver/pkg/apis/tenancy/v1alpha1"
)

func testREST() *REST {
	return NewREST(nil, Options{
		ChartName: "talu-tenant", ChartNamespace: "flux-system",
		DefaultsCM: "talu-tenant-defaults", Interval: "5m",
	})
}

// A Tenant must survive the round trip through its backing HelmRelease unchanged — that projection
// IS the storage layer (there is no second copy), so a lossy field silently drops tenant config.
func TestRoundTrip(t *testing.T) {
	in := &v1alpha1.Tenant{
		ObjectMeta: metav1.ObjectMeta{Name: "acme", Namespace: "tenants"},
		Spec: v1alpha1.TenantSpec{
			ProjectUUID:     "aaaaaaaa-1111-2222-3333-444444444444",
			Members:         []string{"alice@example.org", "bob@example.org"},
			Quota:           map[string]string{"requests.cpu": "4", "requests.memory": "8Gi"},
			Dashboards:      true,
			NetworkBaseline: true,
		},
	}
	out, err := fromHelmRelease(testREST().toHelmRelease(in, "tenants"))
	if err != nil {
		t.Fatalf("fromHelmRelease: %v", err)
	}
	if out.Name != in.Name || out.Spec.ProjectUUID != in.Spec.ProjectUUID {
		t.Errorf("identity lost: %q/%q", out.Name, out.Spec.ProjectUUID)
	}
	if len(out.Spec.Members) != 2 || out.Spec.Members[0] != "alice@example.org" {
		t.Errorf("members lost: %v", out.Spec.Members)
	}
	if out.Spec.Quota["requests.cpu"] != "4" || out.Spec.Quota["requests.memory"] != "8Gi" {
		t.Errorf("quota lost: %v", out.Spec.Quota)
	}
	if !out.Spec.Dashboards || !out.Spec.NetworkBaseline {
		t.Errorf("flags lost: dashboards=%v networkBaseline=%v", out.Spec.Dashboards, out.Spec.NetworkBaseline)
	}
}

// The rendered HelmRelease must carry the ownership label, or the object it creates would be
// invisible to List and unreachable by Get/Update/Delete.
func TestRenderCarriesOwnershipLabel(t *testing.T) {
	u := testREST().toHelmRelease(&v1alpha1.Tenant{
		ObjectMeta: metav1.ObjectMeta{Name: "acme"},
		Spec:       v1alpha1.TenantSpec{ProjectUUID: "uuid"},
	}, "tenants")
	if got := u.GetLabels()[managedByAPILabel]; got != "true" {
		t.Fatalf("%s = %q, want \"true\"", managedByAPILabel, got)
	}
	if got := u.GetLabels()["talu.io/project-uuid"]; got != "uuid" {
		t.Errorf("join key not stamped: %q", got)
	}
}

// Status is projected from the HelmRelease's Ready condition, which is what an orchestrator polls.
func TestPhaseFromReadyCondition(t *testing.T) {
	for _, tc := range []struct {
		status, want string
	}{
		{"True", "Ready"},
		{"False", "Degraded"},
		{"Unknown", "Provisioning"},
	} {
		u := &unstructured.Unstructured{Object: map[string]interface{}{
			"metadata": map[string]interface{}{"name": "acme"},
			"status": map[string]interface{}{"conditions": []interface{}{
				map[string]interface{}{"type": "Ready", "status": tc.status, "reason": "R"},
			}},
		}}
		got, err := fromHelmRelease(u)
		if err != nil {
			t.Fatalf("fromHelmRelease: %v", err)
		}
		if got.Status.Phase != tc.want {
			t.Errorf("Ready=%s -> phase %q, want %q", tc.status, got.Status.Phase, tc.want)
		}
	}
}

// A HelmRelease with no conditions yet (just created) must not read as Ready.
func TestPhasePendingWithoutConditions(t *testing.T) {
	got, err := fromHelmRelease(&unstructured.Unstructured{Object: map[string]interface{}{
		"metadata": map[string]interface{}{"name": "acme"},
	}})
	if err != nil {
		t.Fatalf("fromHelmRelease: %v", err)
	}
	if got.Status.Phase != "Pending" {
		t.Errorf("phase %q, want Pending", got.Status.Phase)
	}
}
