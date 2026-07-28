#!/usr/bin/env python3
"""Idempotently add an HTTP route to BOTH pomerium ConfigMaps (base + live config).

pomerium-base holds the ansible-owned config with __DOMAIN__ tokens; pomerium-config is the live
blob Pomerium reads. Patching the live blob directly (rather than re-rendering from the phys_identity
template) avoids clobbering the dynamically-added kubectl (k8s-<tenant>) routes.

usage: add-pomerium-route.py <host-prefix> <upstream-url> <allowed-user>
  e.g. add-pomerium-route.py clusters http://kamaji-console.kamaji-system.svc:80 alice@talu.local
"""
import json
import subprocess
import sys

import yaml

prefix, upstream, allowed_user = sys.argv[1:4]


def kubectl(*args, capture=False):
    cmd = ["kubectl", "-n", "pomerium", *args]
    if capture:
        return subprocess.check_output(cmd).decode()
    subprocess.run(cmd, check=True)


def domain_token_for(cm):
    if cm == "pomerium-base":
        return "__DOMAIN__"
    cfg = yaml.safe_load(kubectl("get", "cm", cm, "-o", "jsonpath={.data.config\\.yaml}", capture=True))
    return cfg["authenticate_service_url"].split("authenticate.", 1)[1]


for cm, key in [("pomerium-base", "base.yaml"), ("pomerium-config", "config.yaml")]:
    raw = kubectl("get", "cm", cm, "-o", f"jsonpath={{.data.{key.replace('.', chr(92) + '.')}}}", capture=True)
    cfg = yaml.safe_load(raw)
    routes = cfg.setdefault("routes", [])
    frm = f"https://{prefix}.{domain_token_for(cm)}"
    host = f"{prefix}."
    # replace any existing route for this host prefix (idempotent)
    routes[:] = [r for r in routes if not r.get("from", "").startswith(f"https://{host}")]
    routes.append({
        "from": frm,
        "to": upstream,
        "allowed_users": [allowed_user],
        "allow_websockets": True,
    })
    patch = json.dumps({"data": {key: yaml.safe_dump(cfg, default_flow_style=False, sort_keys=False)}})
    kubectl("patch", "cm", cm, "--type", "merge", "-p", patch)
    print(f"{cm}: {prefix} route set -> {upstream}")
