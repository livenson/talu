#!/usr/bin/env python3
"""Make CoreDNS answer *.<lab_domain> locally so the access plane never depends on flaky upstream DNS.

The lab domain is `<floating-ip-dashed>.sslip.io`, which sslip.io resolves to the floating IP. The
management cluster's egress DNS is intermittently flaky here, and Pomerium's OIDC BACK-channel (the
token exchange to Dex at id.<domain>) fails with "server misbehaving" when that upstream lookup
flakes — a 500 on the login callback. Answering these names locally in CoreDNS removes the upstream
dependency entirely: A -> the floating IP; AAAA -> NODATA (clients fall back to A).

CoreDNS here is Talos-bootstrap-managed and has the `reload` plugin, so a bad Corefile is rejected
and the old one kept (no outage). NOTE: a Talos upgrade re-applies the bootstrap manifest and reverts
this — re-run the role after an upgrade.

usage: harden-sslip.py <lab_domain> <floating_ip>
  e.g. harden-sslip.py 92-220-16-211.sslip.io 92.220.16.211
"""
import json
import subprocess
import sys

domain, ip = sys.argv[1:3]


def kc(*args, capture=False):
    cmd = ["kubectl", "-n", "kube-system", *args]
    return subprocess.check_output(cmd).decode() if capture else subprocess.run(cmd, check=True)


cf = kc("get", "cm", "coredns", "-o", "jsonpath={.data.Corefile}", capture=True)
if domain in cf:
    print("already hardened")
    sys.exit(0)

block = (
    f"    # Answer *.{domain} locally (the floating IP) so the Pomerium/Dex back-channel never\n"
    f"    # depends on flaky upstream DNS. A -> floating IP; AAAA -> NODATA (clients fall back to A).\n"
    f"    template IN A {domain} {{\n"
    f'        answer "{{{{ .Name }}}} 60 IN A {ip}"\n'
    f"    }}\n"
    f"    template IN AAAA {domain} {{\n"
    f"        rcode NOERROR\n"
    f"    }}"
)
out = []
for line in cf.split("\n"):
    if line.strip().startswith("forward "):
        out.append(block)
    out.append(line)
kc("patch", "cm", "coredns", "--type", "merge", "-p", json.dumps({"data": {"Corefile": "\n".join(out)}}))
print(f"patched: *.{domain} -> {ip}")
