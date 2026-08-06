// Package server wires the Talu aggregated apiserver.
//
// Authn/authz are DELEGATED to kube-apiserver (TokenReview / SubjectAccessReview), so RBAC on
// tenancy.talu.io resources behaves exactly like RBAC on any built-in resource — which is the whole
// point of problem 2 in docs/architecture/adr-api-layer.md §1.
//
// There is no etcd option here on purpose: this server stores nothing (§2).
package server

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	"k8s.io/apiserver/pkg/registry/rest"
	genericapiserver "k8s.io/apiserver/pkg/server"
	"k8s.io/client-go/dynamic"

	"github.com/livenson/talu/apiserver/pkg/apis/tenancy/v1alpha1"
	tenantstore "github.com/livenson/talu/apiserver/pkg/registry/tenant"
)

var (
	Scheme = runtime.NewScheme()
	Codecs = serializer.NewCodecFactory(Scheme)
)

func init() {
	utilruntime.Must(v1alpha1.AddToScheme(Scheme))
	// The unversioned meta types every apiserver must be able to emit (Status, discovery, …).
	Scheme.AddUnversionedTypes(metav1.Unversioned,
		&metav1.Status{}, &metav1.APIVersions{}, &metav1.APIGroupList{},
		&metav1.APIGroup{}, &metav1.APIResourceList{})
	// Registers ListOptions/GetOptions/DeleteOptions under the meta "v1" group version. Without it
	// the endpoint installer fails with: no kind "ListOptions" is registered for version "v1" —
	// v1alpha1.AddToScheme registers the meta types under OUR group version, which is not the one
	// the parameter codec decodes list/watch query parameters against.
	metav1.AddToGroupVersion(Scheme, schema.GroupVersion{Version: "v1"})
	utilruntime.Must(Scheme.SetVersionPriority(v1alpha1.SchemeGroupVersion))
}

type Config struct {
	Generic *genericapiserver.RecommendedConfig
	Dynamic dynamic.Interface
	Tenant  tenantstore.Options
}

type TaluServer struct {
	GenericAPIServer *genericapiserver.GenericAPIServer
}

func (c Config) New() (*TaluServer, error) {
	gs, err := c.Generic.Complete().New("talu-apiserver", genericapiserver.NewEmptyDelegate())
	if err != nil {
		return nil, err
	}

	info := genericapiserver.NewDefaultAPIGroupInfo(
		v1alpha1.GroupName, Scheme, runtime.NewParameterCodec(Scheme), Codecs)

	info.VersionedResourcesStorageMap["v1alpha1"] = map[string]rest.Storage{
		"tenants": tenantstore.NewREST(c.Dynamic, c.Tenant),
	}

	if err := gs.InstallAPIGroup(&info); err != nil {
		return nil, err
	}
	return &TaluServer{GenericAPIServer: gs}, nil
}
