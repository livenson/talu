#!/usr/bin/env python3
"""Minimal DRIM orchestrator — the DR-service behaviours the format specifies but nobody had run:
DAG ordering from relationships+bootOrder, cycle detection, startupGates, level-2 connectivity,
and launchModes.validation (namespace remap, strict isolation, stubs, TTL, finally-cleanup).

Component MATERIALISATION is deliberately stubbed to a tiny pod per component: restoring real disks
and manifests is proven elsewhere. What is under test here is the ORCHESTRATION.
"""
import argparse, json, subprocess, sys, time, yaml

def kubectl(*a, inp=None, check=True):
    r = subprocess.run(["kubectl", *a], input=inp, capture_output=True, text=True)
    if check and r.returncode: raise RuntimeError(f"kubectl {' '.join(a)}: {r.stderr.strip()[:300]}")
    return r.stdout.strip()

def topo_order(components, relationships):
    """DAG from `relationships` (depends-on) with bootOrder as the tiebreak. Cycles are a
    manifest validation error, per spec §6.4 — not a hang."""
    names = [c["name"] for c in components]
    boot  = {c["name"]: c.get("restore", {}).get("bootOrder", 1000) for c in components}
    deps  = {n: set() for n in names}
    for r in relationships:
        if r.get("type") == "depends-on" and r["from"] in deps and r["to"] in names:
            deps[r["from"]].add(r["to"])
    order, ready = [], set()
    while len(order) < len(names):
        avail = sorted([n for n in names if n not in ready and deps[n] <= ready], key=lambda n: boot[n])
        if not avail:
            raise ValueError(f"cycle in relationships among {sorted(set(names) - ready)}")
        order.append(avail[0]); ready.add(avail[0])
    return order

def apply_component(ns, comp, mode, stubs):
    """Stub materialisation: one pod + service per component. External components become a STUB in
    validation mode (spec §8.3) and are NOT created in recovery mode."""
    name = comp["name"]
    if comp["type"] == "external":
        if mode != "validation": return None
        stub = stubs.get(name, "blackhole")
        port = 25
        body = {"apiVersion": "v1", "kind": "Pod",
                "metadata": {"name": name, "namespace": ns, "labels": {"drim": name, "drim-stub": stub}},
                "spec": {"restartPolicy": "Never", "containers": [{
                    "name": "s", "image": "docker.io/library/python:3-alpine",
                    "command": ["sh", "-c", f"python3 -m http.server {port}"]}]}}
    else:
        port = 5432 if comp["type"] == "vm" else 8080
        body = {"apiVersion": "v1", "kind": "Pod",
                "metadata": {"name": name, "namespace": ns, "labels": {"drim": name}},
                "spec": {"restartPolicy": "Never", "containers": [{
                    "name": "c", "image": "docker.io/library/python:3-alpine",
                    "command": ["sh", "-c", f"python3 -m http.server {port}"]}]}}
    kubectl("apply", "-f", "-", inp=json.dumps(body))
    svc = {"apiVersion": "v1", "kind": "Service",
           "metadata": {"name": name, "namespace": ns},
           "spec": {"selector": {"drim": name}, "ports": [{"port": port, "targetPort": port}]}}
    kubectl("apply", "-f", "-", inp=json.dumps(svc))
    return port

def probe(ns, target, timeout, label):
    """One-shot TCP probe pod — used for BOTH startupGates and level-2 connectivity checks."""
    host, _, port = target.partition(":")
    pod = f"probe-{label}"
    kubectl("-n", ns, "delete", "pod", pod, "--ignore-not-found", check=False)
    body = {"apiVersion": "v1", "kind": "Pod",
            "metadata": {"name": pod, "namespace": ns},
            "spec": {"restartPolicy": "Never", "containers": [{
                "name": "p", "image": "docker.io/alpine/git:latest",
                "command": ["sh", "-c", f"nc -z -w5 {host} {port} && echo REACHABLE || echo blocked"]}]}}
    kubectl("apply", "-f", "-", inp=json.dumps(body))
    deadline = time.time() + timeout
    while time.time() < deadline:
        ph = kubectl("-n", ns, "get", "pod", pod, "-o", "jsonpath={.status.phase}", check=False)
        if ph in ("Succeeded", "Failed"):
            out = kubectl("-n", ns, "logs", pod, check=False)
            return "REACHABLE" in out
        time.sleep(3)
    return False

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--mode", choices=["validation", "recovery"], default="recovery")
    ap.add_argument("--namespace", required=True)
    ap.add_argument("--dry-run-order", action="store_true", help="print the DAG order and exit")
    ap.add_argument("--escape-probe", metavar="HOST:PORT", default=None,
                    help="after startup, probe an OUT-OF-NAMESPACE target. Under isolation: strict "
                         "this MUST be blocked; it is the negative control for the policy.")
    a = ap.parse_args()
    m = yaml.safe_load(open(a.manifest))["spec"]
    lm = m.get("launchModes", {}).get(a.mode, {})
    stubs = {s["component"]: s["stub"] for s in lm.get("network", {}).get("stubs", [])}
    results, t0 = [], time.time()

    try:
        order = topo_order(m["components"], m.get("relationships", []))
    except ValueError as e:
        print(json.dumps({"verdict": "FAILED", "reasonCode": "precondition-failed", "error": str(e)}))
        sys.exit(2)
    print(f"  DAG order: {' -> '.join(order)}", flush=True)
    if a.dry_run_order: return

    ns = a.namespace
    kubectl("apply", "-f", "-", inp=json.dumps({"apiVersion": "v1", "kind": "Namespace",
            "metadata": {"name": ns, "labels": {"pod-security.kubernetes.io/enforce": "privileged",
                                                "drim-mode": a.mode}}}))
    # validation mode: strict isolation == default-deny egress except DNS + in-namespace
    if a.mode == "validation" and lm.get("network", {}).get("isolation") == "strict":
        cnp = {"apiVersion": "cilium.io/v2", "kind": "CiliumNetworkPolicy",
               "metadata": {"name": "drim-isolation", "namespace": ns},
               "spec": {"endpointSelector": {},
                        "egress": [{"toEndpoints": [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": ns}}]},
                                   {"toEndpoints": [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": "kube-system",
                                                                     "k8s:k8s-app": "kube-dns"}}],
                                    "toPorts": [{"ports": [{"port": "53", "protocol": "UDP"}]}]}],
                        "ingress": [{"fromEndpoints": [{"matchLabels": {"k8s:io.kubernetes.pod.namespace": ns}}]}]}}
        kubectl("apply", "-f", "-", inp=json.dumps(cnp))
        print("  isolation: strict — egress restricted to in-namespace + DNS", flush=True)

    try:
        gates = [r for r in m.get("relationships", []) if r.get("startupGate")]
        for name in order:
            comp = next(c for c in m["components"] if c["name"] == name)
            # every gate this component depends on MUST pass before it is created
            for g in [g for g in gates if g["from"] == name]:
                sg = g["startupGate"]
                if sg.get("check") == "none":
                    results.append({"name": f"gate:{name}->{g['to']}", "status": "skipped", "note": "check: none"})
                    continue
                st = time.time()
                ok = probe(ns, sg["target"], sg.get("timeoutSeconds", 60), f"gate-{name}")
                results.append({"name": f"gate:{name}->{g['to']}", "status": "passed" if ok else "failed",
                                "durationMs": int((time.time() - st) * 1000)})
                if not ok:
                    print(json.dumps({"verdict": "FAILED", "reasonCode": "precondition-failed",
                                      "failedGate": f"{name}->{g['to']}", "checks": results}))
                    sys.exit(3)
            port = apply_component(ns, comp, a.mode, stubs)
            if port:
                for _ in range(40):
                    if kubectl("-n", ns, "get", "pod", name, "-o", "jsonpath={.status.phase}", check=False) == "Running":
                        break
                    time.sleep(3)
            results.append({"name": f"start:{name}", "status": "passed",
                            "atMs": int((time.time() - t0) * 1000)})
            print(f"    started {name} at +{int(time.time()-t0)}s", flush=True)

        # level 2 — connectivity, both positive and NEGATIVE assertions
        for lvl in m.get("validation", {}).get("levels", []):
            if lvl["name"] != "connectivity": continue
            for c in lvl.get("checks", []):
                st = time.time()
                ok = probe(ns, c["target"], 60, "l2-" + c["target"].replace(":", "-").replace(".", "-"))
                want = c.get("expect", "reachable") == "reachable"
                results.append({"name": f"level2:{c.get('from','?')}->{c['target']}",
                                "status": "passed" if ok == want else "failed",
                                "expected": c.get("expect", "reachable"),
                                "actual": "reachable" if ok else "blocked",
                                "durationMs": int((time.time() - st) * 1000)})
        verdict = "PASSED" if all(r["status"] != "failed" for r in results) else "FAILED"
        # negative control for isolation: a target OUTSIDE the namespace. Under `isolation: strict`
        # this MUST be blocked; running the identical probe in recovery mode is the A/B that shows
        # the policy — and not a missing listener — is what did the blocking.
        if a.escape_probe:
            st = time.time()
            ok = probe(ns, a.escape_probe, 45, "escape")
            want_blocked = (a.mode == "validation")
            results.append({"name": f"escape:{a.escape_probe}",
                            "status": "passed" if (not ok) == want_blocked else "failed",
                            "expected": "blocked" if want_blocked else "reachable",
                            "actual": "reachable" if ok else "blocked",
                            "durationMs": int((time.time() - st) * 1000)})

        verdict = "PASSED" if all(r["status"] != "failed" for r in results) else "FAILED"
        print(json.dumps({"verdict": verdict, "mode": a.mode, "namespace": ns, "checks": results}, indent=2))
    finally:
        # spec §8.2: cleanup runs even when checks fail (finally semantics)
        if a.mode == "validation":
            ttl = lm.get("ttlSeconds")
            kubectl("annotate", "ns", ns, f"drim.io/ttl-seconds={ttl}", "--overwrite", check=False)
            kubectl("delete", "ns", ns, "--wait=false", check=False)
            print(f"  CLEANUP: namespace {ns} deleted (ttlSeconds={ttl}, finally-semantics)", flush=True)

main()
