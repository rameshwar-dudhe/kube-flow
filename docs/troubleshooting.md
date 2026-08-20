# Kubeflow Troubleshooting (Hinglish)

Pehla step hamesha:
```bash
make status     # sirf unhealthy pods dikhata hai
make verify     # poora health check, batata hai kya toota hai
```

---

## 1. Har pod fail ho raha hai: `violates PodSecurity "restricted:latest"`

### Symptom A — `istio-init` container
```
Error creating: pods "..." is forbidden: violates PodSecurity "restricted:latest":
unrestricted capabilities (container "istio-init" must not include "NET_ADMIN", "NET_RAW"
in securityContext.capabilities.add), runAsNonRoot != true ...
```

**Kya ho raha hai:** Istio ka sidecar injector privileged `istio-init` container daal raha hai,
par Kubeflow ke namespaces par PodSecurity `restricted` laga hai. Iska matlab hai ki injector ko
pata hi nahi ki Istio CNI plugin install hai.

**Check kijiye:**
```bash
kubectl -n istio-system get cm istio-sidecar-injector -o jsonpath='{.data.values}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['pilot']['cni'])"
```
`enabled: false` aaya to yahi problem hai.

**Fix:** `values/istiod.yaml` me dono keys honi chahiye:
```yaml
istio_cni:
  enabled: true
pilot:
  cni:
    enabled: true      # <- injection template SIRF isko padhta hai
```
```bash
make infra
kubectl -n kubeflow rollout restart deploy,statefulset
```

> **Yaad rakhiye:** sirf `istio_cni.enabled` set karna **kaafi nahi hai**. Wo ek alag ConfigMap
> bharta hai. Injection template `.Values.pilot.cni.enabled` par gate karta hai. Dono chahiye.

Sahi hone par init container ka naam `istio-init` nahi, **`istio-validation`** dikhega:
```bash
kubectl get pods -n kubeflow -o jsonpath='{.items[0].spec.initContainers[*].name}'
# istio-validation istio-proxy
```

### Symptom B — `seccompProfile`
```
violates PodSecurity "restricted:latest": seccompProfile
(pod or containers "istio-validation", "istio-proxy" must set
 securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

**Fix:** `values/istiod.yaml`:
```yaml
global:
  proxy:
    seccompProfile:
      type: RuntimeDefault
```
```bash
make infra && kubectl -n kubeflow rollout restart deploy,statefulset
```

---

## 2. Login page nahi khul raha / 403 / RBAC access denied

Sabse common wajah: mesh config me `oauth2-proxy` extensionProvider missing hai.

```bash
kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}' | grep -A3 extensionProviders
```

Kuch nahi mila to Kubeflow ki AuthorizationPolicies (jo `action: CUSTOM` use karti hain) ka
provider hi nahi hai. Fix `values/istiod.yaml` me:
```yaml
meshConfig:
  extensionProviders:
    - name: oauth2-proxy
      envoyExtAuthzHttp:
        service: oauth2-proxy.oauth2-proxy.svc.cluster.local
        port: 80
        headersToDownstreamOnDeny: [content-type, set-cookie]
        headersToUpstreamOnAllow:
          [authorization, path, x-auth-request-email, x-auth-request-groups, x-auth-request-user]
        includeRequestHeadersInCheck: [authorization, cookie]
```
```bash
make infra
kubectl -n istio-system rollout restart deploy istiod
kubectl -n oauth2-proxy rollout restart deploy oauth2-proxy
```

---

## 2b. Login ho jaata hai par har page `403 RBAC: access denied` deta hai

**Symptom:** Dex login successful, saare pods `Running`, phir bhi dashboard aur har UI 403 deti hai.
Body me sirf `RBAC: access denied` (19 bytes) hota hai.

**Wajah:** ingress gateway ka **ServiceAccount naam galat** hai. Kubeflow ki har app ki
AuthorizationPolicy sirf ye principal allow karti hai:
```
cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account
```
Istio ka Helm gateway chart SA ka naam release name se banata hai (`istio-ingressgateway`), jo
match nahi karta.

**Check:**
```bash
kubectl -n istio-system get pods -l istio=ingressgateway \
  -o jsonpath='{.items[0].spec.serviceAccountName}'
# "istio-ingressgateway-service-account" hona chahiye
```

Aur ye confirm karta hai ki deny gateway par nahi, destination pod par ho raha hai:
```bash
kubectl -n istio-system logs -l istio=ingressgateway --tail=20 | grep '"GET /'
# "403 - via_upstream" => gateway ne bhej diya, sidecar ne roka
```

**Fix** — `values/istio-ingressgateway.yaml`:
```yaml
serviceAccount:
  create: true
  name: istio-ingressgateway-service-account
```
```bash
make infra
```

> Ye bug pod-health checks se **kabhi nahi** pakda jaayega. Isi liye `make verify` asli login
> karke dashboard hit karti hai.

---

## 3. Login loop — password daalne ke baad wapas login page

Istio ne dex ke JWT public keys placeholder ke saath cache kar li hain (istiod dex se pehle up ho
gaya tha).

```bash
kubectl -n istio-system logs -l app=istiod --tail=100 | grep -i jwks
```

**Fix:**
```bash
kubectl -n auth rollout restart deploy dex
kubectl -n istio-system rollout restart deploy istiod
```
`PILOT_JWT_PUB_KEY_REFRESH_INTERVAL=1m` already set hai, to 1-2 minute me apne aap theek ho jaana
chahiye.

---

## 4. Pods `Pending` — RAM khatam

```bash
kubectl describe pod <pod> -n kubeflow | grep -A5 Events
# "0/2 nodes are available: Insufficient memory"
kubectl top nodes
```

Cluster me sirf ~14.4Gi hai. Trim order (upar se neeche) — `cluster.env` me:
```bash
INSTALL_SPARK="off"      # sabse pehle ye
INSTALL_TRAINER="off"    # phir ye
INSTALL_KATIB="off"      # aur phir ye
```
```bash
helm uninstall spark-operator -n kubeflow
make core && make apps
```

**Asli solution:** VMs ki RAM 16Gi per node kar dijiye.

Check kijiye ki control-plane par schedule ho bhi raha hai:
```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
# dono me <none> hona chahiye
kubectl taint nodes k8s-cp-0 node-role.kubernetes.io/control-plane-
```

---

## 5. PVC hamesha `Pending`

```bash
kubectl get pvc -A
kubectl get sc
```

**a) Koi default StorageClass nahi:**
```bash
kubectl get sc
# "local-path (default)" dikhna chahiye
make infra
```

**b) `WaitForFirstConsumer` — ye normal hai.** PVC tab tak Pending rahegi jab tak koi pod use
mount na kare. Sirf tab problem hai jab owner pod bhi stuck ho.

**c) Node par disk full:**
```bash
ssh root@192.168.56.134 'df -h /'
ssh root@192.168.56.134 'du -sh /opt/local-path-provisioner/*'
```

---

## 6. Pods bahut der `PodInitializing` / `ContainerCreating`

99% cases me ye **slow image pull** hai, error nahi:
```bash
kubectl describe pod <pod> -n kubeflow | tail -10
# "Pulling image ..." dikhega
```
Kubeflow ~30 images pull karta hai. Pehle install me **15-25 minute** normal hai.

Agar `istio-validation` init container par atka hai, to Istio CNI theek se kaam nahi kar raha:
```bash
kubectl -n kubeflow logs <pod> -c istio-validation
# "Validation passed, iptables rules established" aana chahiye
kubectl -n istio-system get pods -l k8s-app=istio-cni-node
ssh root@192.168.56.134 'ls -la /etc/cni/net.d/ | grep istio'
```

---

## 6b. Rollout deadlock — duplicate ReplicaSets ne RAM kha li

**Symptom:** bahut saare pods `1/2 PodInitializing` par ghanton atke rehte hain, koi progress nahi.
Images node par already hain, phir bhi pods ready nahi ho rahe.

**Wajah:** agar aapne `kubectl rollout restart` tab chalaya jab pehla rollout abhi chal hi raha tha,
to har Deployment ke paas **do active ReplicaSet** ban jaate hain. Purane RS ke pods RAM pakde rehte
hain, aur naye RS ke pods ko RAM milti hi nahi — dono atak jaate hain. Tight cluster par ye
permanent deadlock ban jaata hai.

**Check:**
```bash
kubectl get rs -n kubeflow --no-headers | awk '$2>0' | wc -l   # active ReplicaSets
kubectl get deploy -n kubeflow --no-headers | wc -l            # Deployments
```
Pehla number dusre se zyada hai to duplicates hain.

**Fix — har Deployment ka sirf latest revision rakhiye:**
```bash
kubectl get rs -n kubeflow -o json | python3 -c "
import sys, json, subprocess, collections
d = json.load(sys.stdin)
by_owner = collections.defaultdict(list)
for rs in d['items']:
    if rs['spec']['replicas'] == 0: continue
    owners = rs['metadata'].get('ownerReferences', [])
    if not owners: continue
    rev = int(rs['metadata']['annotations'].get('deployment.kubernetes.io/revision','0'))
    by_owner[owners[0]['name']].append((rev, rs['metadata']['name']))
for dep, rss in by_owner.items():
    if len(rss) < 2: continue
    rss.sort()
    for _, name in rss[:-1]:
        subprocess.run(['kubectl','delete','rs','-n','kubeflow',name,'--wait=false'])
"
```

> **Bachne ka tareeka:** rollout restart karne se pehle current rollout ko khatam hone dijiye.
> Ek hi baar me sab restart karna ho to pehle `kubectl rollout status` se confirm kar lijiye.

---

## 7. `no matches for kind "Profile"` / `ensure CRDs are installed first`

**Ye normal hai** aur script khud handle karti hai. CR apne CRD se pehle create nahi ho sakta;
`02-kubeflow-core.sh` 15 baar retry karti hai.

Agar 15 attempts ke baad bhi fail ho:
```bash
kubectl get crd | grep kubeflow
kubectl apply --server-side --force-conflicts -f .cache/kubeflow-core.yaml
```

---

## 8. NodePort se access nahi ho raha

```bash
curl -v http://192.168.56.134:31380
kubectl -n istio-system get svc istio-ingressgateway
```

**a) Gateway resource missing:**
```bash
kubectl -n istio-system get gateway istio-ingressgateway
# nahi hai to:
kubectl apply -f .cache/community-distribution/common/istio/istio-install/base/gateway.yaml
```

**b) Gateway labels match nahi kar rahe.** Gateway `app: istio-ingressgateway` + `istio: ingressgateway`
select karta hai. Helm release ka naam `istio-ingressgateway` hona hi chahiye:
```bash
kubectl -n istio-system get pods -l istio=ingressgateway
# khali aaya to release galat naam se laga hai
helm uninstall istio-ingressgateway -n istio-system && make infra
```

**c) Firewall:**
```bash
ssh root@192.168.56.134 'iptables -L -n | grep 31380; ufw status'
```

**d) Fallback:**
```bash
kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80
```

---

## 9. Central Dashboard me component nahi dikh raha (KServe/Endpoints)

Helm se install kiye components apne aap dashboard sidebar me register nahi hote — wo menu
`centraldashboard-config` ConfigMap me hai jiska owner Kubeflow ka kustomize hai.

```bash
kubectl -n kubeflow get cm centraldashboard-config -o jsonpath='{.data.links}' | python3 -m json.tool
```

Entry missing hai to:
```bash
make apps      # models-web-app overlay dobara apply karta hai
kubectl -n kubeflow rollout restart deploy dashboard
```

Phir bhi nahi to us component ko kustomize par switch kar dijiye — `cluster.env`:
```bash
INSTALL_KSERVE="kustomize"
```
```bash
helm uninstall kserve kserve-crd -n kubeflow
make core
```

---

## 9b. KServe: `no matches for kind "ClusterStorageContainer"`

**Symptom:** `make apps` doosri baar chalane par fail hota hai:
```
Error: UPGRADE FAILED: resource mapping not found for name: "default"
no matches for kind "ClusterStorageContainer" in version "serving.kserve.io/v1alpha1"
ensure CRDs are installed first
```

**Wajah:** `kserve-crd` chart me ye ek CRD `lookup` se guard kiya hua hai:
```gotemplate
{{- $existing := lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" "clusterstoragecontainers.serving.kserve.io" -}}
{{- if not $existing }} ... {{- end }}
```
Pehle install par CRD nahi hota → render hota hai → ban jaata hai.
**Upgrade par CRD exist karta hai → guard kuch render nahi karta → Helm use "removed resource"
samajh kar DELETE kar deta hai.** Uske turant baad `kserve-resources` fail ho jaata hai.

**Fix:** `03-helm-apps.sh` ab ye khud handle karti hai — agar release pehle se hai to
`helm upgrade` skip karti hai, aur CRD missing ho to chart ki `files/` se direct apply kar deti hai.

Manually theek karna ho to:
```bash
kubectl apply --server-side \
  -f .cache/kserve-crd/files/serving.kserve.io_clusterstoragecontainers.yaml
make apps
```

> **Sabak:** `kserve-crd` par kabhi seedha `helm upgrade` mat chalaiye. `make apps` use kijiye.

---

## 9c. Dashboard me "Model Registry" click karne par 404

Expected hai. Model Registry Kubeflow Hub se aata hai, jo RAM bachane ke liye band hai
(`INSTALL_HUB="off"`). Menu entry dashboard config me phir bhi rehti hai.

Chahiye to on kar dijiye (~2112Mi RAM + 20GB PVC):
```bash
# cluster.env
INSTALL_HUB="kustomize"
make core
```

---

## 10. cert-manager webhook errors

```
Internal error occurred: failed calling webhook "webhook.cert-manager.io"
```
```bash
kubectl -n cert-manager get pods
kubectl -n cert-manager logs -l app=webhook --tail=50
```
Zyadatar timing ka issue hai — thoda ruk kar dobara apply kijiye:
```bash
make core
```

KServe me `certificate signed by unknown authority` aaye to check kijiye ki `inject-ca-from`
annotation usi namespace ko point kare jisme Certificate hai (hamare Helm install me dono
`kubeflow` me hote hain):
```bash
kubectl get validatingwebhookconfiguration -o yaml | grep inject-ca-from
```

---

## 11. Namespace `Terminating` par atka hua hai

```bash
kubectl get namespace kubeflow -o json | python3 -c "import sys,json; print(json.load(sys.stdin)['spec'])"
```
Finalizers stuck hain to:
```bash
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n1 kubectl get -n kubeflow --show-kind --ignore-not-found 2>/dev/null
```
Bache hue resources delete kijiye. Last resort (**dhyan se**):
```bash
kubectl get namespace kubeflow -o json \
  | python3 -c "import sys,json;d=json.load(sys.stdin);d['spec']['finalizers']=[];print(json.dumps(d))" \
  | kubectl replace --raw /api/v1/namespaces/kubeflow/finalize -f -
```

---

## 12. Sab kuch reset karna hai

```bash
make uninstall     # confirmation maangta hai
make clean         # local cache delete
make all           # scratch se dobara
```

---

## Useful commands

```bash
# Kaunsa pod kis node par
kubectl get pods -n kubeflow -o wide

# Resource usage
kubectl top nodes && kubectl top pods -n kubeflow --sort-by=memory

# Kisi pod ke saare logs (sidecar ke saath)
kubectl -n kubeflow logs <pod> --all-containers --tail=100

# Istio proxy config check
kubectl -n kubeflow exec <pod> -c istio-proxy -- pilot-agent request GET config_dump | head -50

# Kaunsi AuthorizationPolicies lagi hain
kubectl get authorizationpolicy -A

# Recent errors across cluster
kubectl get events -A --sort-by=.lastTimestamp | grep -i -E "error|fail" | tail -20
```
