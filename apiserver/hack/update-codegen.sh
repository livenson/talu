#!/usr/bin/env bash
# Regenerate the OpenAPI definitions. Run after ANY change to pkg/apis/**/types.go — apiserver 0.34
# refuses to start without an OpenAPI v3 config ("OpenAPIV3 config must not be nil"), and that config
# is built from the generated map, so a stale map is a boot failure, not a docs problem.
#
# The generated file is COMMITTED: CI has no codegen step, and making the image build run a generator
# would put the module proxy on the critical path of every build.
#
#   ./hack/update-codegen.sh            # needs a local Go toolchain
#   podman run --rm -v "$PWD":/src:z -w /src docker.io/library/golang:1.24 ./hack/update-codegen.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PKG=github.com/livenson/talu/apiserver

# The meta/runtime/version packages are generated alongside ours on purpose: our types reference
# metav1.ObjectMeta and friends, and a $ref with no matching definition makes the spec build fail.
go run k8s.io/kube-openapi/cmd/openapi-gen \
  --output-dir ./pkg/generated/openapi \
  --output-pkg "${PKG}/pkg/generated/openapi" \
  --output-file zz_generated.openapi.go \
  --go-header-file /dev/null \
  k8s.io/apimachinery/pkg/apis/meta/v1 \
  k8s.io/apimachinery/pkg/runtime \
  k8s.io/apimachinery/pkg/version \
  "${PKG}/pkg/apis/tenancy/v1alpha1"

echo "generated pkg/generated/openapi/zz_generated.openapi.go"
