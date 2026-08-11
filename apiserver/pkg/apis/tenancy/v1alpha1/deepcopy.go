package v1alpha1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
)

// Hand-written deepcopy. These types are small and stable; adding code-generation for three structs
// would cost more than it saves. Keep in sync with types.go.

func (in *TenantSpec) DeepCopyInto(out *TenantSpec) {
	*out = *in
	if in.Members != nil {
		out.Members = make([]string, len(in.Members))
		copy(out.Members, in.Members)
	}
	if in.Quota != nil {
		out.Quota = make(map[string]string, len(in.Quota))
		for k, v := range in.Quota {
			out.Quota[k] = v
		}
	}
}

func (in *TenantStatus) DeepCopyInto(out *TenantStatus) {
	*out = *in
	out.VMs = in.VMs
	if in.Conditions != nil {
		out.Conditions = make([]metav1.Condition, len(in.Conditions))
		for i := range in.Conditions {
			in.Conditions[i].DeepCopyInto(&out.Conditions[i])
		}
	}
}

func (in *Tenant) DeepCopyInto(out *Tenant) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}

func (in *Tenant) DeepCopy() *Tenant {
	if in == nil {
		return nil
	}
	out := new(Tenant)
	in.DeepCopyInto(out)
	return out
}

func (in *Tenant) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *TenantList) DeepCopyInto(out *TenantList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		out.Items = make([]Tenant, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

func (in *TenantList) DeepCopy() *TenantList {
	if in == nil {
		return nil
	}
	out := new(TenantList)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *TenantVMSpec) DeepCopyInto(out *TenantVMSpec) {
	*out = *in
	if in.SecurityGroups != nil {
		out.SecurityGroups = make([]string, len(in.SecurityGroups))
		copy(out.SecurityGroups, in.SecurityGroups)
	}
	if in.DataDisks != nil {
		out.DataDisks = make([]TenantVMDataDisk, len(in.DataDisks))
		copy(out.DataDisks, in.DataDisks)
	}
}

func (in *TenantVMStatus) DeepCopyInto(out *TenantVMStatus) {
	*out = *in
	if in.Conditions != nil {
		out.Conditions = make([]metav1.Condition, len(in.Conditions))
		for i := range in.Conditions {
			in.Conditions[i].DeepCopyInto(&out.Conditions[i])
		}
	}
}

func (in *TenantVM) DeepCopyInto(out *TenantVM) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}

func (in *TenantVM) DeepCopy() *TenantVM {
	if in == nil {
		return nil
	}
	out := new(TenantVM)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantVM) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *TenantVMList) DeepCopyInto(out *TenantVMList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		out.Items = make([]TenantVM, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

func (in *TenantVMList) DeepCopy() *TenantVMList {
	if in == nil {
		return nil
	}
	out := new(TenantVMList)
	in.DeepCopyInto(out)
	return out
}

func (in *TenantVMList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *ManagedClusterSpec) DeepCopyInto(out *ManagedClusterSpec) {
	*out = *in
	out.Workers = in.Workers
}

func (in *ManagedClusterStatus) DeepCopyInto(out *ManagedClusterStatus) {
	*out = *in
	if in.Conditions != nil {
		out.Conditions = make([]metav1.Condition, len(in.Conditions))
		for i := range in.Conditions {
			in.Conditions[i].DeepCopyInto(&out.Conditions[i])
		}
	}
}

func (in *ManagedCluster) DeepCopyInto(out *ManagedCluster) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ObjectMeta.DeepCopyInto(&out.ObjectMeta)
	in.Spec.DeepCopyInto(&out.Spec)
	in.Status.DeepCopyInto(&out.Status)
}

func (in *ManagedCluster) DeepCopy() *ManagedCluster {
	if in == nil {
		return nil
	}
	out := new(ManagedCluster)
	in.DeepCopyInto(out)
	return out
}

func (in *ManagedCluster) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}

func (in *ManagedClusterList) DeepCopyInto(out *ManagedClusterList) {
	*out = *in
	out.TypeMeta = in.TypeMeta
	in.ListMeta.DeepCopyInto(&out.ListMeta)
	if in.Items != nil {
		out.Items = make([]ManagedCluster, len(in.Items))
		for i := range in.Items {
			in.Items[i].DeepCopyInto(&out.Items[i])
		}
	}
}

func (in *ManagedClusterList) DeepCopy() *ManagedClusterList {
	if in == nil {
		return nil
	}
	out := new(ManagedClusterList)
	in.DeepCopyInto(out)
	return out
}

func (in *ManagedClusterList) DeepCopyObject() runtime.Object {
	if c := in.DeepCopy(); c != nil {
		return c
	}
	return nil
}
