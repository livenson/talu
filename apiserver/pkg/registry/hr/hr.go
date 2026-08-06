// Package hr holds the plumbing every Talu kind shares: they are all projections over a Flux
// HelmRelease, differing only in which chart they render and how spec maps to values.
package hr

import (
	"context"

	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

// GVR is the object every Talu kind projects onto. The dynamic client keeps Flux out of this
// module's dependency graph — it is an implementation detail, not a contract.
var GVR = schema.GroupVersionResource{
	Group: "helm.toolkit.fluxcd.io", Version: "v2", Resource: "helmreleases",
}

// ManagedByAPILabel marks the releases this API owns. Releases written by hand or reconciled from
// Git deliberately do not carry it, and are invisible to every kind.
const ManagedByAPILabel = "talu.io/managed-by-api"

// TenantLabel scopes a release to its tenant, so VMs can be listed per tenant namespace.
const TenantLabel = "talu.io/tenant"

// GetOwned fetches a release and refuses anything this API did not create.
//
// NotFound rather than Forbidden is deliberate: to this API the object genuinely does not exist, and
// saying otherwise leaks the existence of releases the caller cannot address. Without this check a
// Get would expose — and a Delete reading through it would DESTROY — a Git-managed release that
// merely shares a name.
func GetOwned(ctx context.Context, c dynamic.Interface, ns, name string, gr schema.GroupResource) (*unstructured.Unstructured, error) {
	u, err := c.Resource(GVR).Namespace(ns).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		if errors.IsNotFound(err) {
			return nil, errors.NewNotFound(gr, name)
		}
		return nil, err
	}
	if u.GetLabels()[ManagedByAPILabel] != "true" {
		return nil, errors.NewNotFound(gr, name)
	}
	return u, nil
}

// Phase rolls the release's Ready condition into the coarse phase Talu's kinds report. A release
// being torn down is NOT "Degraded" — that is merely what Ready says while helm uninstalls — so the
// deletion timestamp wins.
func Phase(u *unstructured.Unstructured) (string, []metav1.Condition) {
	if u.GetDeletionTimestamp() != nil {
		return "Deleting", nil
	}
	conds, _, _ := unstructured.NestedSlice(u.Object, "status", "conditions")
	phase := "Pending"
	out := []metav1.Condition{}
	for _, c := range conds {
		cm, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		cond := metav1.Condition{}
		cond.Type, _ = cm["type"].(string)
		st, _ := cm["status"].(string)
		cond.Status = metav1.ConditionStatus(st)
		cond.Reason, _ = cm["reason"].(string)
		cond.Message, _ = cm["message"].(string)
		if cond.Reason == "" {
			cond.Reason = "Unknown"
		}
		out = append(out, cond)
		if cond.Type == "Ready" {
			switch cond.Status {
			case metav1.ConditionTrue:
				phase = "Ready"
			case metav1.ConditionFalse:
				phase = "Degraded"
			default:
				phase = "Provisioning"
			}
		}
	}
	return phase, out
}

// Release builds the HelmRelease that backs an object of any Talu kind.
func Release(name, ns, chart, chartNS, defaultsCM, interval, projectUUID, tenant string,
	values map[string]interface{}, extraLabels map[string]string,
	extraValuesFrom ...map[string]interface{}) *unstructured.Unstructured {

	labels := map[string]interface{}{
		"app.kubernetes.io/part-of": "talu",
		"talu.io/project-uuid":      projectUUID,
		ManagedByAPILabel:           "true",
	}
	if tenant != "" {
		labels[TenantLabel] = tenant
	}
	for k, v := range extraLabels {
		labels[k] = v
	}
	valuesFrom := []interface{}{map[string]interface{}{
		"kind": "ConfigMap", "name": defaultsCM, "valuesKey": "values.yaml", "optional": true,
	}}
	// Merged AFTER the site defaults and BEFORE spec.values, exactly as the tenancy role orders them.
	for _, e := range extraValuesFrom {
		valuesFrom = append(valuesFrom, e)
	}
	return &unstructured.Unstructured{Object: map[string]interface{}{
		"apiVersion": "helm.toolkit.fluxcd.io/v2",
		"kind":       "HelmRelease",
		"metadata":   map[string]interface{}{"name": name, "namespace": ns, "labels": labels},
		"spec": map[string]interface{}{
			"interval":    interval,
			"releaseName": name,
			"chartRef": map[string]interface{}{
				"kind": "OCIRepository", "name": chart, "namespace": chartNS,
			},
			"valuesFrom": valuesFrom,
			"values":     values,
		},
	}}
}
