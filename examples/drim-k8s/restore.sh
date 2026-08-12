#!/bin/bash
set -eu
: "${KUBECONFIG:?set KUBECONFIG to the TARGET tenant cluster}"
PKG="${PKG:?set PKG to the package revision directory}"

echo "########## LEVEL 0 — package integrity (§8.1) ##########"
cd "$PKG"
python3 - <<'PY'
import hashlib,json,sys
idx=json.load(open('index.json')); bad=0
for p,a in sorted(idx['artifacts'].items()):
    h=hashlib.sha256(open(p,'rb').read()).hexdigest()
    ok = h==a['sha256']; bad += (not ok)
    print(f"  {'OK  ' if ok else 'FAIL'} {p}")
print("  verdict:", "PASSED" if not bad else f"FAILED ({bad})")
sys.exit(1 if bad else 0)
PY

echo "########## RESTORE — unpack + apply the profile's storageClass remap ##########"
rm -rf /tmp/res && mkdir -p /tmp/res
zstd -dc snapshots/k8s/resources.tar.zst | tar -C /tmp/res -xf -
python3 - <<'PY'
import json
d=json.load(open('/tmp/res/resources.json'))
for it in d['items']:
    if it['kind']=='PersistentVolumeClaim':
        old=it['spec'].get('storageClassName')
        it['spec']['storageClassName']='local-path'      # profiles[].platform.k8s.storageClass
        print(f"  remapped PVC {it['metadata']['name']}: {old} -> local-path")
json.dump(d,open('/tmp/res/resources.json','w'),indent=2)
PY
kubectl create namespace "${NS:-billing}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n "${NS:-billing}" apply -f /tmp/res/resources.json
