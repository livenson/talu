#!/usr/bin/env python3
"""Talu route portal — a read-only landing page that lists every route Pomerium exposes.

Routes have TWO possible sources, because the cluster is mid-migration
(docs/architecture/adr-pomerium-ingress.md):

  TALU_ROUTE_SOURCE=config    (default, pre-swap) — parse the live `pomerium-config` ConfigMap,
                              mounted read-only at $POMERIUM_CONFIG.
  TALU_ROUTE_SOURCE=ingress   (post-swap)         — list `Ingress` objects whose ingressClassName is
                              the Pomerium class, which is where routes live once the Ingress
                              Controller owns them.

This switch is deliberate rather than automatic. After the swap `pomerium-config` is ORPHANED but
still present, so a portal that kept parsing it would render a stale route list forever while looking
perfectly healthy — showing routes that no longer exist and hiding every new one. Auto-detecting
"which source is real" would guess wrong in exactly that window, since the Ingress objects are
created BEFORE the swap and sit inert. So the source is stated, and flipped in the same change that
flips `ingress.enabled` and suspends route-sync.

Still stdlib-only: no YAML library, no HTTP client dependency. In `ingress` mode it needs read-only
`list` on Ingresses (see rbac.yaml) — a genuine change from "no cluster API access at all", and the
narrowest grant that can answer the question.
"""
import html
import json
import os
import re
import ssl
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CONFIG_PATH = os.environ.get("POMERIUM_CONFIG", "/config/config.yaml")
LISTEN_PORT = int(os.environ.get("PORT", "8080"))
ROUTE_SOURCE = os.environ.get("TALU_ROUTE_SOURCE", "config").strip().lower()
INGRESS_CLASS = os.environ.get("TALU_INGRESS_CLASS", "pomerium")
ANN = "ingress.pomerium.io/"
# The site domain. route-sync resolved it at run time from the talu-platform ConfigMap (lab-notes #40,
# the single source both writers read); in ingress mode there is no config blob to recover it from, so
# the same ConfigMap is mounted here rather than inventing a second source of truth.
DOMAIN_FILE = os.environ.get("TALU_DOMAIN_FILE", "/platform/domain")
SA_DIR = "/var/run/secrets/kubernetes.io/serviceaccount"
# External port the provider forwards to Pomerium's Native SSH proxy (ssh_address :2222). Site-specific:
# the physical lab forwards :2222 straight through; the old OpenStack lab used :23 (socat→NodePort). Set
# SSH_PORT per environment on the portal Deployment; default matches Pomerium's own listener.
SSH_PORT = os.environ.get("SSH_PORT", "2222")

# Friendly names/descriptions per platform route, keyed on the `from` sub-domain. Anything not listed
# still renders (with its upstream as the description) — so new platform routes never silently vanish.
PLATFORM = {
    "id":           ("Identity", "Dex / OIDC — sign-in endpoint (used by the login redirect; not a page)"),
    "whoami":       ("Session", "whoami — your current identity &amp; request headers"),
    "vms":          ("VM console", "KubeVirt Manager — create, start/stop, serial console"),
    "perses":       ("Dashboards", "Perses — fleet metrics · Access Audit · VM Logs"),
    "hubble":       ("Network flows", "Hubble UI — live Cilium service map &amp; flows"),
    "clusters":     ("Tenant clusters", "Headlamp — the provisioned managed (KaaS) clusters"),
    "alertmanager": ("Alerts", "Alertmanager — firing &amp; silenced alerts"),
}
# Managed-cluster kube-apiserver routes (k8s-<tenant>) get their own section rather than being
# mistaken for platform pages — they are kubectl endpoints, not links to open in a browser.
K8S_PREFIX = "k8s-"
SKIP_SUBDOMAINS = {"authenticate"}  # the auth service itself is not a user destination
# OIDC IdP endpoint: reachable only via the OAuth login redirect (/dex/auth?…); its root path 404s, so
# show it (users like knowing the IdP) but DON'T make it a link that dead-ends on a 404.
NONLINK_SUBDOMAINS = {"id"}


def load_domain():
    """Site domain from the talu-platform ConfigMap, when mounted. '' if unavailable."""
    try:
        return open(DOMAIN_FILE).read().strip()
    except OSError:
        return ""


def _emails_from_policy(text):
    """Pull the allow-list out of a PPL policy annotation (`email: { in: [a, b] }`)."""
    out = []
    for grp in re.findall(r"in:\s*\[([^\]]*)\]", text or ""):
        out += [x.strip() for x in grp.split(",") if x.strip()]
    return out


def load_routes_from_ingresses():
    """List Pomerium-class Ingresses and shape them like config routes.

    Returns the SAME dicts as the config parser (from / to / public / allow-list), so classify() and
    render() below are untouched by the migration — only where the facts come from changes.
    """
    host = os.environ.get("KUBERNETES_SERVICE_HOST", "kubernetes.default.svc")
    port = os.environ.get("KUBERNETES_SERVICE_PORT_HTTPS", "443")
    token = open(f"{SA_DIR}/token").read().strip()
    ctx = ssl.create_default_context(cafile=f"{SA_DIR}/ca.crt")
    req = urllib.request.Request(
        f"https://{host}:{port}/apis/networking.k8s.io/v1/ingresses",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, context=ctx, timeout=10) as resp:
        items = json.load(resp).get("items", [])

    routes = []
    for ing in items:
        spec = ing.get("spec") or {}
        if spec.get("ingressClassName") != INGRESS_CLASS:
            continue
        meta = ing.get("metadata") or {}
        ns = meta.get("namespace", "")
        ann = meta.get("annotations") or {}
        is_ssh = ann.get(ANN + "ssh_upstream") == "true"
        emails = _emails_from_policy(ann.get(ANN + "policy"))
        allowed = [x.strip() for x in (ann.get(ANN + "allowed_users") or "").strip("[] ").split(",") if x.strip()]
        for rule in spec.get("rules") or []:
            h = rule.get("host")
            if not h:
                continue  # a catch-all host is not a nameable destination
            paths = ((rule.get("http") or {}).get("paths")) or []
            svc = ((paths[0].get("backend") or {}).get("service")) if paths else None
            to = ""
            if svc:
                p = (svc.get("port") or {}).get("number", "")
                to = f"{'ssh' if is_ssh else 'http'}://{svc.get('name','')}.{ns}.svc:{p}"
            r = {"from": (f"ssh://{h}" if is_ssh else f"https://{h}"), "to": to}
            if ann.get(ANN + "allow_public_unauthenticated_access") == "true":
                r["public"] = True
            if allowed:
                r["allowed_users"] = allowed
            if emails:
                r["policy_emails"] = emails
            routes.append(r)
    return routes


def load_routes():
    """Dispatch on TALU_ROUTE_SOURCE. Domain comes from the mounted ConfigMap when present."""
    if ROUTE_SOURCE == "ingress":
        return load_domain(), load_routes_from_ingresses()
    domain, routes = load_routes_from_config()
    return (load_domain() or domain), routes


def load_routes_from_config():
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
    if sub.startswith(K8S_PREFIX):
        tenant = sub[len(K8S_PREFIX):]
        return ("Managed clusters", f"{html.escape(tenant)} · kube-apiserver",
                "kubectl endpoint — sign in with your OIDC kubeconfig, not a browser", frm, False)
    if sub.endswith("-dashboard"):
        ns = sub[: -len("-dashboard")]
        return ("Tenant dashboards", f"{html.escape(ns)} · dashboard",
                "Per-tenant Perses — this tenant's metrics &amp; VM logs", frm, True)
    if sub in PLATFORM:
        title, desc = PLATFORM[sub]
        return ("Platform", title, desc, frm, sub not in NONLINK_SUBDOMAINS)
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
    # Name the source on the page: during the migration "which mechanism is actually serving these
    # routes" is the question an operator most needs answered, and a page that hides it can look
    # right while describing the wrong world.
    src = ("Ingress objects (ingressClassName: " + html.escape(INGRESS_CLASS) + ")"
           if ROUTE_SOURCE == "ingress" else "pomerium-config")
    empty = ("No routes found — are there Ingresses with ingressClassName: "
             + html.escape(INGRESS_CLASS) + "?") if ROUTE_SOURCE == "ingress" else \
            "No routes found — is pomerium-config present?"
    return f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Talu — routes on {dom}</title><style>{CSS}</style></head>
<body><div class="wrap">
<h1>Talu</h1>
<p class="sub">exposed routes on {dom} · generated live from {src}</p>
{''.join(body) or f'<p class="desc">{empty}</p>'}
<p class="foot">Every route enters through Pomerium (the only ingress). Links open the service;
you'll be asked to sign in unless the route is marked <span class="acc pub">public</span>.
SSH routes use Native SSH: <code>ssh &lt;principal&gt;@&lt;vm&gt;@ssh.{dom} -p {SSH_PORT}</code>.</p>
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
            missing = ("service-account token not mounted (ingress mode needs it)"
                       if ROUTE_SOURCE == "ingress" else "pomerium-config not mounted yet")
            page = f"<h1>Talu portal</h1><p>{html.escape(missing)}.</p>".encode(); code = 200
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
