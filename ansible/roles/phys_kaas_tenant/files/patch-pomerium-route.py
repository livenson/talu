#!/usr/bin/env python3
"""Add (or refresh) the kubectl route for a tenant cluster in BOTH pomerium ConfigMaps.

pomerium-base holds the ansible-owned static config with __DOMAIN__ tokens (route-sync, when
enabled, renders the live blob from it); pomerium-config is the live blob Pomerium reads. While
route-sync is suspended on phys, both must be patched. Idempotent: an existing k8s-<tenant> route
is replaced in full (so token/CA rotation is a re-run).

usage: patch-pomerium-route.py <tenant> <endpoint> <token-file> <ca-b64-file> <allowed-user>
"""
import json
import subprocess
import sys

import yaml

tenant, endpoint, token_file, ca_file, allowed_user = sys.argv[1:6]
token = open(token_file).read().strip()
ca = open(ca_file).read().strip()


def kubectl(*args, capture=False):
    cmd = ["kubectl", "-n", "pomerium", *args]
    if capture:
        return subprocess.check_output(cmd).decode()
    subprocess.run(cmd, check=True)


def domain_token_for(cm):
    if cm == "pomerium-base":
        return "__DOMAIN__"
    # derive the live domain from the authenticate URL in the live blob
    cfg = yaml.safe_load(kubectl("get", "cm", cm, "-o", "jsonpath={.data.config\\.yaml}", capture=True))
    return cfg["authenticate_service_url"].split("authenticate.", 1)[1]


for cm, key in [("pomerium-base", "base.yaml"), ("pomerium-config", "config.yaml")]:
    raw = kubectl("get", "cm", cm, "-o", f"jsonpath={{.data.{key.replace('.', chr(92) + '.')}}}", capture=True)
    cfg = yaml.safe_load(raw)
    routes = cfg.setdefault("routes", [])
    host = f"k8s-{tenant}."
    routes[:] = [r for r in routes if host not in r.get("from", "")]
    routes.append({
        "from": f"https://k8s-{tenant}.{domain_token_for(cm)}",
        "to": endpoint,
        "tls_custom_ca": ca,
        "kubernetes_service_account_token": token,
        "allowed_users": [allowed_user],
        "allow_spdy": True,
        "allow_websockets": True,
        "timeout": "120s",
    })
    patch = json.dumps({"data": {key: yaml.safe_dump(cfg, default_flow_style=False, sort_keys=False)}})
    kubectl("patch", "cm", cm, "--type", "merge", "-p", patch)
    print(f"{cm}: k8s-{tenant} route set")
