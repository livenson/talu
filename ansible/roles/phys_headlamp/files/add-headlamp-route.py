#!/usr/bin/env python3
"""Set the admin-only Pomerium route for Headlamp.

Headlamp shows the TENANT clusters (from their kubeconfigs, client-cert creds), so no bearer-token
injection is needed — a single Pomerium/Dex SSO gates access and Headlamp authenticates to each tenant
apiserver with the mounted kubeconfig. Patches the LIVE pomerium-config directly (so the dynamic
k8s-<tenant> kubectl routes are not clobbered) and pomerium-base for record. Idempotent.

usage: add-headlamp-route.py <upstream-url> <allowed-user>
"""
import json
import subprocess
import sys

import yaml

upstream, allowed_user = sys.argv[1:3]


def kubectl(*args, capture=False):
    cmd = ["kubectl", "-n", "pomerium", *args]
    return subprocess.check_output(cmd).decode() if capture else subprocess.run(cmd, check=True)


def domain_token_for(cm):
    if cm == "pomerium-base":
        return "__DOMAIN__"
    cfg = yaml.safe_load(kubectl("get", "cm", cm, "-o", 'go-template={{index .data "config.yaml"}}', capture=True))
    return cfg["authenticate_service_url"].split("authenticate.", 1)[1]


for cm, key in [("pomerium-base", "base.yaml"), ("pomerium-config", "config.yaml")]:
    cfg = yaml.safe_load(kubectl("get", "cm", cm, "-o", f'go-template={{{{index .data "{key}"}}}}', capture=True))
    routes = cfg.setdefault("routes", [])
    routes[:] = [r for r in routes if not r.get("from", "").startswith("https://clusters.")]
    routes.append({
        "from": f"https://clusters.{domain_token_for(cm)}",
        "to": upstream,
        "allowed_users": [allowed_user],
        "allow_websockets": True,
    })
    kubectl("patch", "cm", cm, "--type", "merge", "-p",
            json.dumps({"data": {key: yaml.safe_dump(cfg, default_flow_style=False, sort_keys=False)}}))
    print(f"{cm}: clusters route -> {upstream} (admin-only)")
