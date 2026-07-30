#!/usr/bin/env python3
"""Enforce the compatibility matrix against the versions pinned across the repo.

The matrix (components/platform/upgrades/compat-matrix.yaml) is the single source of truth for which
component versions may run together (the binding constraint: KubeVirt v1.8 -> Kubernetes <= 1.35).
This is the CI leg of the three-way enforcement (Kyverno gate at runtime, Renovate on bump PRs, this
at build time). It catches exactly the kind of drift that already happened once — the Cilium pin in
the Flux HelmRelease lagging the phys lab / chart / group_vars.

Fails (exit 1) if any pinned version disagrees with the matrix or exceeds a version ceiling.
"""
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
errors = []


def load(path):
    return yaml.safe_load((ROOT / path).read_text())


def minor(v):
    """('v1.35.7'|'1.35') -> (1, 35) for a major.minor comparison."""
    parts = re.sub(r"^v", "", v).split(".")
    return (int(parts[0]), int(parts[1]))


# ── the matrix (flat keys) ──────────────────────────────────────────────────────────────────────
matrix = load("components/platform/upgrades/compat-matrix.yaml")["data"]
k8s_max = matrix["kubernetes.max"]
cilium_want = matrix["cilium.current"]

# ── 1. every Cilium pin must equal matrix cilium.current ─────────────────────────────────────────
cilium_pins = {
    "compat-matrix": cilium_want,
    "flux HelmRelease": load("components/infrastructure/cilium/helmrelease.yaml")["spec"]["chart"]["spec"]["version"],
    "group_vars/all.yml": load("ansible/group_vars/all.yml")["cilium_version"],
    "group_vars/phys.yml": load("ansible/group_vars/phys.yml")["cilium_version"],
    "cluster-chart values": str(load("components/tenancy/cluster-chart/values.yaml")["ciliumVersion"]),
}
for where, pin in cilium_pins.items():
    if pin != cilium_want:
        errors.append(f"Cilium pin drift: {where} = {pin!r}, matrix cilium.current = {cilium_want!r}")

# ── 2. Kubernetes versions must not exceed the matrix ceiling ────────────────────────────────────
k8s_pins = {
    "group_vars/phys.yml kubernetes_version": load("ansible/group_vars/phys.yml")["kubernetes_version"],
    "cluster-chart kubernetesVersion (tenant)": load("components/tenancy/cluster-chart/values.yaml")["kubernetesVersion"],
}
for where, pin in k8s_pins.items():
    if minor(pin) > minor(k8s_max):
        errors.append(f"Kubernetes over ceiling: {where} = {pin!r} > matrix kubernetes.max = {k8s_max!r} "
                      f"(KubeVirt {matrix['kubevirt.current']} caps k8s at {k8s_max})")

if errors:
    print("compat-matrix check FAILED:")
    for e in errors:
        print(f"  ✗ {e}")
    sys.exit(1)
print(f"compat-matrix OK — Cilium {cilium_want} consistent across {len(cilium_pins)} pins; "
      f"k8s pins within ceiling {k8s_max}.")
