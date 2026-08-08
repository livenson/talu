package vm

import (
	"testing"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/livenson/talu/apiserver/pkg/apis/tenancy/v1alpha1"
	"github.com/livenson/talu/apiserver/pkg/registry/hr"
)

func testREST() *REST {
	return NewREST(nil, Options{
		ChartName: "talu-vm", ChartNamespace: "flux-system",
		DefaultsCM: "talu-vm-defaults", Interval: "5m",
		ReleaseNamespace: "tenants", CASecretName: "pomerium-user-ca",
	})
}

func sampleVM() *v1alpha1.TenantVM {
	return &v1alpha1.TenantVM{
		ObjectMeta: metav1.ObjectMeta{
			Name: "web1", Namespace: "acme",
			Annotations: map[string]string{
				"talu.io/project-uuid":  "uuid-1",
				"talu.io/allowed-users": "alice@x,bob@x",
			},
		},
		Spec: v1alpha1.TenantVMSpec{
			Size: "small", Principal: "alice", RootDiskSize: "20Gi",
			SecurityGroups: []string{"web", "db"},
		},
	}
}

// The projection IS the storage layer, so a lost field silently drops VM config.
func TestRoundTrip(t *testing.T) {
	out, err := fromRelease(testREST().toRelease(sampleVM(), "acme"))
	if err != nil {
		t.Fatalf("fromRelease: %v", err)
	}
	if out.Name != "web1" || out.Namespace != "acme" {
		t.Errorf("identity lost: %s/%s", out.Namespace, out.Name)
	}
	if out.Spec.Size != "small" || out.Spec.Principal != "alice" || out.Spec.RootDiskSize != "20Gi" {
		t.Errorf("spec lost: %+v", out.Spec)
	}
	if len(out.Spec.SecurityGroups) != 2 || out.Spec.SecurityGroups[0] != "web" {
		t.Errorf("securityGroups lost: %v", out.Spec.SecurityGroups)
	}
}

// A VM's release must be named exactly as the tenancy role names it, or the typed API and the Git
// path would produce two releases for one VM.
func TestReleaseNameMatchesTheRole(t *testing.T) {
	if got := testREST().toRelease(sampleVM(), "acme").GetName(); got != "acme-web1" {
		t.Fatalf("release name = %q, want \"acme-web1\"", got)
	}
}

// Without the kind label a TenantVM would be readable — and deletable — as a Tenant.
func TestKindAndScopeLabels(t *testing.T) {
	l := testREST().toRelease(sampleVM(), "acme").GetLabels()
	for k, want := range map[string]string{
		hr.KindLabel: "tenantvm", hr.ManagedByAPILabel: "true",
		hr.TenantLabel: "acme", "talu.io/vm": "web1", "talu.io/project-uuid": "uuid-1",
	} {
		if l[k] != want {
			t.Errorf("label %s = %q, want %q", k, l[k], want)
		}
	}
}

// The talu-vm chart REQUIRES a non-empty sshUserCaPubKey. The role injects it live from a ConfigMap
// so a CA rotation needs no edit; when the API server omitted this, every VM it created sat
// Ready=False and nothing said why.
func TestCAInjectionIsWired(t *testing.T) {
	u := testREST().toRelease(sampleVM(), "acme")
	vf, _, _ := unstructuredSlice(u.Object, "spec", "valuesFrom")
	found := false
	for _, e := range vf {
		m, ok := e.(map[string]interface{})
		if ok && m["name"] == "pomerium-user-ca" && m["targetPath"] == "sshUserCaPubKey" {
			found = true
		}
	}
	if !found {
		t.Fatalf("no pomerium-user-ca valuesFrom entry: %v", vf)
	}
}

// allowedUsers comes from the owning Tenant; it drives the ssh Service annotation the Pomerium route
// renderer reads. When it was missing the route was left unscoped.
func TestAllowedUsersInheritedFromTenant(t *testing.T) {
	u := testREST().toRelease(sampleVM(), "acme")
	vals, _, _ := unstructuredMap(u.Object, "spec", "values")
	au, ok := vals["allowedUsers"].([]interface{})
	if !ok || len(au) != 2 || au[0] != "alice@x" {
		t.Fatalf("allowedUsers = %v", vals["allowedUsers"])
	}
}

func unstructuredMap(obj map[string]interface{}, path ...string) (map[string]interface{}, bool, error) {
	cur := obj
	for i, p := range path {
		v, ok := cur[p]
		if !ok {
			return nil, false, nil
		}
		m, ok := v.(map[string]interface{})
		if !ok {
			return nil, false, nil
		}
		if i == len(path)-1 {
			return m, true, nil
		}
		cur = m
	}
	return nil, false, nil
}

func unstructuredSlice(obj map[string]interface{}, path ...string) ([]interface{}, bool, error) {
	m, ok, _ := unstructuredMap(obj, path[:len(path)-1]...)
	if !ok {
		return nil, false, nil
	}
	s, ok := m[path[len(path)-1]].([]interface{})
	return s, ok, nil
}
