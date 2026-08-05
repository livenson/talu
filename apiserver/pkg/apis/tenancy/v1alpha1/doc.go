// +k8s:openapi-gen=true

// Package v1alpha1 defines the Talu tenant API served by the aggregated apiserver.
//
// These types are a VIEW over the Flux HelmRelease that renders the tenant — there is no second copy
// of the truth in etcd. See docs/architecture/adr-api-layer.md §2.
//
// The openapi-gen marker lives HERE rather than in types.go: gengo picks up the package marker from
// the conventional doc.go, and with it in types.go the generator silently emitted zero definitions
// for this package — which surfaces only at boot as "cannot find model definition for ... Tenant".
package v1alpha1
