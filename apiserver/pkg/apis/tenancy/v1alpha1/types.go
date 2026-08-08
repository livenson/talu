package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

// Tenant is the namespace half of a Talu tenant: quota, members, network baseline, dashboards.
// Each VM is a separate TenantVM object (ADR §10.1).
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

// TenantVM is one tenant VM. It is its OWN object rather than a field of Tenant so that
// "may add a VM" is grantable without granting "may change the quota or the member list" — see
// docs/architecture/adr-api-layer.md §10.1.
//
// It lives in the TENANT's namespace, while its backing HelmRelease lives in the management
// namespace alongside the Tenant's; the storage layer maps between them.
type TenantVM struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   TenantVMSpec   `json:"spec,omitempty"`
	Status TenantVMStatus `json:"status,omitempty"`
}

type TenantVMSpec struct {
	// Size is a named size backed by a VirtualMachineClusterInstancetype (components/tenancy/sizes/).
	// KubeVirt rejects a VM that overrides its instancetype, so a size is enforced, not advisory —
	// and it is the only way this API expresses vCPU at all.
	Size string `json:"size,omitempty"`
	// Principal is the guest OS user and SSH certificate principal.
	Principal string `json:"principal,omitempty"`
	// RootDiskSize applies when the site's image catalog uses a persistent DataVolume.
	RootDiskSize string `json:"rootDiskSize,omitempty"`
	// GuestSecretsRef names a Secret rendered into the guest as /etc/talu/app.env.
	GuestSecretsRef string `json:"guestSecretsRef,omitempty"`
	// SecurityGroups are the tenant security groups this VM joins; they become labels the tenant's
	// CiliumNetworkPolicies select on.
	SecurityGroups []string `json:"securityGroups,omitempty"`
}

type TenantVMStatus struct {
	Phase      string             `json:"phase,omitempty"`
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

type TenantVMList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []TenantVM `json:"items"`
}

// ManagedCluster is a tenant's own Kubernetes cluster on the same substrate (KaaS).
//
// Named ManagedCluster, not Cluster: cluster.x-k8s.io/Cluster already runs on this substrate (CAPI
// drives KaaS), and a second `kubectl get cluster` would be ambiguous for operators.
type ManagedCluster struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ManagedClusterSpec   `json:"spec,omitempty"`
	Status ManagedClusterStatus `json:"status,omitempty"`
}

type ManagedClusterSpec struct {
	// ProjectUUID is the manager join key stamped on every rendered object.
	ProjectUUID string `json:"projectUuid"`
	// KubernetesVersion must have a matching capk container-disk image.
	KubernetesVersion string `json:"kubernetesVersion,omitempty"`
	// ControlPlaneReplicas spread across management nodes.
	ControlPlaneReplicas int32 `json:"controlPlaneReplicas,omitempty"`
	// Workers sizing. Replicas is ignored once autoscaling is enabled — the autoscaler owns it.
	Workers ManagedClusterWorkers `json:"workers,omitempty"`
	// AdminUser gets cluster-admin inside the tenant cluster via the Pomerium impersonation route.
	AdminUser string `json:"adminUser,omitempty"`
	// Backup enables in-tenant Velero DR; the endpoint, bucket and credentials are the site's.
	Backup bool `json:"backup,omitempty"`
}

type ManagedClusterWorkers struct {
	Replicas    int32 `json:"replicas,omitempty"`
	Cores       int32 `json:"cores,omitempty"`
	MemoryGiB   int32 `json:"memoryGiB,omitempty"`
	Autoscaling bool  `json:"autoscaling,omitempty"`
	Min         int32 `json:"min,omitempty"`
	Max         int32 `json:"max,omitempty"`
}

type ManagedClusterStatus struct {
	Phase      string             `json:"phase,omitempty"`
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

type ManagedClusterList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ManagedCluster `json:"items"`
}
