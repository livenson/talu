#!/usr/bin/env python3
"""Talu route portal — a read-only landing page that lists every route Pomerium exposes.

The routes are read from the live `pomerium-config` (the same ConfigMap the route renderer writes),
mounted read-only at $POMERIUM_CONFIG. So this page never drifts: it shows exactly what is exposed,
to whom. No cluster API access, no state — just parse + render on each request.
"""
import html
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_PATH = os.environ.get("POMERIUM_CONFIG", "/config/config.yaml")
LISTEN_PORT = int(os.environ.get("PORT", "8080"))

# Friendly names/descriptions per platform route, keyed on the `from` sub-domain. Anything not listed
# still renders (with its upstream as the description) — so new platform routes never silently vanish.
PLATFORM = {
    "id":           ("Identity", "Dex / OIDC — sign-in &amp; token issuance"),
    "whoami":       ("Session", "whoami — your current identity &amp; request headers"),
    "vms":          ("VM console", "KubeVirt Manager — create, start/stop, serial console"),
    "perses":       ("Dashboards", "Perses — fleet metrics · Access Audit · VM Logs"),
    "hubble":       ("Network flows", "Hubble UI — live Cilium service map &amp; flows"),
}
SKIP_SUBDOMAINS = {"authenticate"}  # the auth service itself is not a user destination


def load_routes():
    """Parse the pomerium config WITHOUT a YAML library (no runtime deps / no egress needed).

    Talu renders this config itself (dev/lab/expose-vm.sh · components/tenancy/flux/route-sync.yaml) in
    a stable, simple shape, so a targeted parser is reliable — and if the format ever surprises it, the
    page degrades to "no routes" rather than crashing. We only need from / to / the allow-list.
    """
    text = open(CONFIG_PATH).read()
    m = re.search(r"authenticate_service_url:\s*https://authenticate\.(\S+)", text)
    domain = m.group(1) if m else ""
    idx = text.find("\nroutes:")
    blocks = re.split(r"\n\s*-\s+from:", text[idx:]) if idx >= 0 else []
    routes = []
    for b in blocks[1:]:
        route = {"from": b.splitlines()[0].strip()}
        mto = re.search(r"\bto:\s*(\S+)", b)
        route["to"] = mto.group(1) if mto else ""
        if re.search(r"allow_public_unauthenticated_access:\s*true", b):
            route["public"] = True
        mau = re.search(r"allowed_users:\s*\[([^\]]*)\]", b)
        if mau:
            route["allowed_users"] = [x.strip() for x in mau.group(1).split(",") if x.strip()]
        emails = re.findall(r"email:\s*\{\s*in:\s*\[([^\]]*)\]", b)
        if emails:
            route["policy_emails"] = [x.strip() for e in emails for x in e.split(",") if x.strip()]
        routes.append(route)
    return domain, routes


def access_of(route):
    """Human-readable allow-list for a route."""
    if route.get("public"):
        return ("public", True)
    users = route.get("allowed_users") or route.get("policy_emails")
    if users:
        return (", ".join(users), False)
    return ("authenticated", False)


def classify(route, domain):
    """Return (section, title, desc, url, is_link) or None to skip."""
    frm = route.get("from", "")
    to = route.get("to", "")
    if frm.startswith("ssh://"):
        vm = frm[len("ssh://"):]
        return ("Tenant VMs", f"ssh · {html.escape(vm)}",
                "Native-SSH to the VM through Pomerium (no public :22)", frm, False)
    host = frm.split("://", 1)[-1]
    if domain and host == domain:
        return None  # the portal (this page) itself
    sub = host.split(".", 1)[0]
    if sub in SKIP_SUBDOMAINS:
        return None
    if sub.endswith("-dashboard"):
        ns = sub[: -len("-dashboard")]
        return ("Tenant dashboards", f"{html.escape(ns)} · dashboard",
                "Per-tenant Perses — this tenant's metrics &amp; VM logs", frm, True)
    if sub in PLATFORM:
        title, desc = PLATFORM[sub]
        return ("Platform", title, desc, frm, True)
    # unknown platform-ish route: show it with its upstream so nothing is hidden
    return ("Platform", html.escape(sub), f"upstream: <code>{html.escape(to)}</code>", frm, True)


CSS = """
:root{--ink:#26303b;--muted:#5a6672;--pine:#2e6a4e;--amber:#c6871f;--paper:#f7f5f0;--card:#fff;--line:#e2ddd3}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font:15px/1.5 ui-sans-serif,-apple-system,'Segoe UI',Roboto,Helvetica,Arial,sans-serif}
.wrap{max-width:860px;margin:0 auto;padding:40px 24px 64px}
h1{font-size:30px;margin:0;color:var(--pine)}
.sub{color:var(--muted);font:13px/1.5 ui-monospace,'SF Mono',Menlo,Consolas,monospace;margin:6px 0 0}
h2{font-size:12px;letter-spacing:1.2px;text-transform:uppercase;color:var(--pine);margin:34px 0 12px;border-bottom:1px solid var(--line);padding-bottom:6px}
.row{display:flex;align-items:baseline;gap:14px;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:12px 16px;margin:8px 0;text-decoration:none;color:inherit}
a.row:hover{border-color:#cdbfa2}
.name{font-weight:700;min-width:150px}
.desc{color:var(--muted);font-size:13px;flex:1}
.meta{text-align:right;white-space:nowrap;font:12px ui-monospace,'SF Mono',Menlo,Consolas,monospace}
.url{color:var(--pine)}
.acc{display:inline-block;margin-top:3px;font-size:11px;padding:1px 7px;border-radius:20px;background:#eef3ef;color:#4a5a50}
.acc.pub{background:#fbf3e4;color:#9a7715}
.foot{color:var(--muted);font-size:12px;margin-top:36px;border-top:1px solid var(--line);padding-top:12px}
code{font:12px ui-monospace,'SF Mono',Menlo,Consolas,monospace;color:var(--ink)}
"""


def render(domain, routes):
    sections = {}
    for r in routes:
        c = classify(r, domain)
        if not c:
            continue
        section, title, desc, url, is_link = c
        acc, is_pub = access_of(r)
        sections.setdefault(section, []).append((title, desc, url, is_link, acc, is_pub))
    order = ["Platform", "Tenant dashboards", "Tenant VMs"]
    body = []
    for section in order + [s for s in sections if s not in order]:
        rows = sections.get(section)
        if not rows:
            continue
        body.append(f"<h2>{html.escape(section)}</h2>")
        for title, desc, url, is_link, acc, is_pub in sorted(rows, key=lambda x: x[0].lower()):
            acccls = "acc pub" if is_pub else "acc"
            disp = html.escape(url)
            meta = f'<span class="url">{disp}</span><br><span class="{acccls}">{html.escape(acc)}</span>'
            inner = (f'<span class="name">{title}</span>'
                     f'<span class="desc">{desc}</span>'
                     f'<span class="meta">{meta}</span>')
            if is_link:
                body.append(f'<a class="row" href="{disp}">{inner}</a>')
            else:
                body.append(f'<div class="row">{inner}</div>')
    dom = html.escape(domain or "this cluster")
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Talu — routes on {dom}</title><style>{CSS}</style></head>
<body><div class="wrap">
<h1>Talu</h1>
<p class="sub">exposed routes on {dom} · generated live from pomerium-config</p>
{''.join(body) or '<p class="desc">No routes found — is pomerium-config present?</p>'}
<p class="foot">Every route enters through Pomerium (the only ingress). Links open the service;
you'll be asked to sign in unless the route is marked <span class="acc pub">public</span>.
SSH routes use Native SSH: <code>ssh &lt;principal&gt;@&lt;vm&gt;@ssh.{dom} -p 23</code>.</p>
</div></body></html>"""


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            self.send_response(200); self.end_headers(); self.wfile.write(b"ok"); return
        try:
            domain, routes = load_routes()
            page = render(domain, routes).encode()
            code = 200
        except FileNotFoundError:
            page = b"<h1>Talu portal</h1><p>pomerium-config not mounted yet.</p>"; code = 200
        except Exception as e:  # never 500 the landing page
            page = f"<h1>Talu portal</h1><pre>{html.escape(str(e))}</pre>".encode(); code = 200
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(page)))
        self.end_headers()
        self.wfile.write(page)

    def log_message(self, *a):
        pass  # quiet


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
