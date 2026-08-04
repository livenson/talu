// Package v1alpha1 defines the Talu tenant API served by the aggregated apiserver.
//
// These types are a VIEW over the Flux HelmRelease that renders the tenant — there is no second copy
// of the truth in etcd. See docs/architecture/adr-api-layer.md §2.
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// Tenant is the namespace half of a Talu tenant: quota, members, network baseline, dashboards.
// Each VM is a separate VirtualMachine object (ADR §10.1).
type Tenant struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   TenantSpec   `json:"spec,omitempty"`
	Status TenantStatus `json:"status,omitempty"`
}

type TenantSpec struct {
	// ProjectUUID is stamped on every rendered object as talu.io/project-uuid — the manager join key.
	ProjectUUID string `json:"projectUuid"`
	// Members are the emails allowed to SSH into this tenant's VMs and hold its scoped RBAC role.
	Members []string `json:"members,omitempty"`
	// Quota maps directly to the rendered ResourceQuota's hard limits (e.g. requests.cpu: "4").
	Quota map[string]string `json:"quota,omitempty"`
	// Dashboards renders the per-tenant Perses + prom-label-proxy stack.
	Dashboards bool `json:"dashboards,omitempty"`
	// NetworkBaseline flips the tenant's VMs to default-deny (Layer B).
	NetworkBaseline bool `json:"networkBaseline,omitempty"`
}

type TenantStatus struct {
	// Phase is a coarse rollup: Pending | Provisioning | Ready | Degraded.
	Phase string `json:"phase,omitempty"`
	// Conditions are projected from the backing HelmRelease.
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

type TenantList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Tenant `json:"items"`
}
