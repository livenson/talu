#!/bin/bash
# DRIM capture for a type:k8s component — §6.2 resourceCapture + §4 package layout.
set -eu
: "${KUBECONFIG:?set KUBECONFIG to the SOURCE tenant cluster}"
NS="${NS:-billing}"
REV=$(date -u +%Y-%m-%dT%H-%MZ)
PKG="${PKG_ROOT:-$PWD/drim-pkg}/$REV"
mkdir -p "$PKG"/snapshots/k8s/pv "$PKG"/representation-info "$PKG"/logs

# --- resource dump, namespace-scoped, include-list per the manifest -------------------------------
INCLUDE="deployment,service,configmap,persistentvolumeclaim"
mkdir -p /tmp/cap && rm -rf /tmp/cap/* && cd /tmp/cap
kubectl -n "$NS" get $INCLUDE -o json > raw.json

# stripFields: metadata.uid/resourceVersion/status/spec.clusterIP — plus the cluster-specific
# bindings that make a manifest un-restorable elsewhere. Secrets are NEVER captured (§7).
python3 - <<'PY'
import json
d=json.load(open('/tmp/cap/raw.json'))
out=[]
for it in d.get('items',[]):
    m=it.setdefault('metadata',{})
    for k in ('uid','resourceVersion','creationTimestamp','generation','managedFields','selfLink'):
        m.pop(k,None)
    m.get('annotations',{}).pop('kubectl.kubernetes.io/last-applied-configuration',None)
    if not m.get('annotations'): m.pop('annotations',None)
    it.pop('status',None)
    sp=it.get('spec',{})
    if it['kind']=='Service':
        for k in ('clusterIP','clusterIPs','ipFamilies','ipFamilyPolicy','internalTrafficPolicy','sessionAffinity'):
            sp.pop(k,None)
    if it['kind']=='PersistentVolumeClaim':
        sp.pop('volumeName',None); sp.pop('volumeMode',None)
        # spec.volumeName alone is NOT enough. These annotations make the binding controller
        # believe the claim was already bound; with no PV it goes straight to Lost, and the
        # provisioner annotations still name the SOURCE cluster's CSI driver.
        for a in ('pv.kubernetes.io/bind-completed',
                  'pv.kubernetes.io/bound-by-controller',
                  'volume.kubernetes.io/storage-provisioner',
                  'volume.beta.kubernetes.io/storage-provisioner',
                  'volume.kubernetes.io/selected-node'):
            m.get('annotations',{}).pop(a,None)
        m.pop('finalizers',None)
        if not m.get('annotations'): m.pop('annotations',None)
    if it['kind']=='Secret':
        continue
    # kube-root-ca.crt is auto-created per namespace and holds the SOURCE cluster's CA bundle.
    # A naive include-list captures it; restoring it into another cluster injects the wrong CA.
    if it['kind']=='ConfigMap' and m['name']=='kube-root-ca.crt':
        continue
    out.append(it)
json.dump({'apiVersion':'v1','kind':'List','items':out}, open('/tmp/cap/resources.json','w'), indent=2)
print(f"captured {len(out)} objects:", sorted({o['kind'] for o in out}))
PY
tar -C /tmp/cap -cf - resources.json | zstd -q -o "$PKG/snapshots/k8s/resources.tar.zst" -f

# --- PV data: filesystem-level archive (§14 q2: no CSI snapshot export here) ----------------------
POD=$(kubectl -n "$NS" get pod -l app=billing-api -o jsonpath='{.items[0].metadata.name}')
kubectl -n "$NS" exec "$POD" -- tar -C /usr/share/nginx/html/data -cf - . \
  | zstd -q -o "$PKG/snapshots/k8s/pv/billing-data.tar.zst" -f

# --- representation information (§4.1) -----------------------------------------------------------
cat > "$PKG/representation-info/tool-versions.json" <<EOF
{
  "capturedBy": "hand-rolled DRIM capture (no DR service exists yet)",
  "kubectl": "$(kubectl version --client -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])')",
  "sourceCluster": { "distribution": "Kamaji hosted CP + KubeVirt workers", "version": "v1.34.1" },
  "storage": { "sourceStorageClass": "kubevirt", "driver": "csi.kubevirt.io", "backing": "infra ceph-block (RBD)" },
  "archiveFormats": { "resources": "tar+zstd", "pvData": "tar+zstd" }
}
EOF
echo "$PKG"
