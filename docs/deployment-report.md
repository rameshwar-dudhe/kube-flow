# Kubeflow Deployment Report

**Date:** 2026-08-12
**Cluster:** `192.168.56.134` (k8s-cp-0) + `192.168.56.135` (k8s-w-0), Kubernetes v1.36.3
**Kubeflow:** 26.03.1
**Outcome:** ✅ Successfully deployed and verified end-to-end, then torn down.

> Ye report us deployment ka permanent record hai. Cluster se sab kuch hata diya gaya tha,
> par is repo se `make all` chala kar exactly yahi setup dobara ban jaayega.

---

## 1. Executive summary

Ek 2-node Kubernetes cluster par poora Kubeflow platform **Helm-first hybrid** approach se deploy
kiya gaya. Sab kuch scripted, idempotent aur reproducible hai.

**Result:** 46 pods Running across 6 namespaces, 10 Helm releases, 3 PVCs Bound, aur end-to-end
login + Kubeflow Pipelines API write verified.

**Total time:** ~60 minutes (zyadatar image pulls — VMs ka internet ~1.2 MB/s tha).

---

## 2. Sabse important finding — pure Helm possible nahi hai

Original ask "Kubeflow deploy using Helm" tha. Research se ye nikla:

**Kubeflow ka koi single Helm chart exist nahi karta**, aur ab koi distribution aisa offer bhi
nahi karti. Ye Kubeflow ki design choice hai — Helm me woh dependency sequencing nahi hai jo
~30 components ko sahi order me deploy karne ke liye chahiye.

| Option | Investigate karne par mila | Verdict |
|---|---|---|
| **deployKF** | Last commit **May 2024** (2+ saal purana). Kubeflow 1.8-era par pinned. | ❌ Dead. K8s 1.36 par chalta hi nahi |
| **Official `experimental/helm/charts`** | Sirf 3 components: hub, katib, kserve-models-web-app. Katib chart v0.16.0 vs required v0.19.0 | ⚠️ Incomplete + version mismatch |
| **Kubeflow Pipelines chart** | Exist hi nahi karta | ❌ Platform ka core hissa |
| **Official kustomize manifests** | Poora platform, K8s 1.36 supported, actively maintained | ✅ Supported |
| **Per-component official charts** | KServe, Trainer, Spark Operator ke genuine charts hain | ✅ Used |

**Decision:** Helm-first hybrid — jahan genuine version-matched chart hai wahan Helm, sirf wahan
kustomize jahan koi chart hai hi nahi.

---

## 3. Deployed architecture

### Helm se (6 → 10 releases)

| Release | Namespace | Chart | Version |
|---|---|---|---|
| local-path-provisioner | local-path-storage | local-path-provisioner | 0.0.37 |
| cert-manager | cert-manager | cert-manager | v1.20.2 |
| istio-base | istio-system | base | 1.30.1 |
| istiod | istio-system | istiod | 1.30.1 |
| istio-cni | istio-system | cni | 1.30.1 |
| istio-ingressgateway | istio-system | gateway | 1.30.1 |
| kserve-crd | kubeflow | kserve-crd | v0.18.0 |
| kserve | kubeflow | kserve-resources | v0.18.0 |
| kubeflow-trainer | kubeflow | kubeflow-trainer | 2.2.0 |
| spark-operator | kubeflow | spark-operator | 2.5.0 |

### kustomize se (koi chart nahi tha)

dex 2.45.1 · oauth2-proxy 7.15.2 · Kubeflow Pipelines 2.16.1 · Central Dashboard v2.0.0 ·
profile-controller · Notebooks v1.11.0 · Katib v0.19.0 · KServe models web app v0.18.0 ·
kubeflow-namespace/roles · kubeflow-istio-resources · user-namespace

### Deliberately disabled (RAM budget)

| Component | Saved | Reason |
|---|---|---|
| Kubeflow Hub | 2112Mi + 20GB PVC | Optional model registry |
| Knative | 1038Mi + 1450m CPU | Sirf KServe Serverless ke liye; RawDeployment use kiya |
| training-operator v1.9.2 | 25Mi | Legacy, Trainer v2.2.0 ne replace kiya |

Full footprint 12341Mi tha → trim ke baad ~9.0Gi, jo 14.4Gi me comfortably fit hua.

---

## 4. Cluster ki starting state aur jo fix karna pada

| Issue | Status pehle | Fix |
|---|---|---|
| **StorageClass** | Koi nahi thi — har PVC Pending rehti | local-path-provisioner, default mark kiya |
| **LoadBalancer** | Koi nahi | NodePort 31380 |
| **control-plane taint** | `NoSchedule` — sirf 7.2Gi schedulable | Untaint → 14.4Gi |
| **helm/kubectl/kustomize** | Installed hi nahi the | v3.21.3 / v1.36.3 / v5.8.1 |
| **inotify limits** | Default | 655360 watches, dono nodes |

---

## 5. Chaar critical gotchas (sabse valuable output)

Istio ko Helm se lagane par Kubeflow ke kustomize overlay ki config manually reproduce karni
padti hai. Inme se koi bhi miss ho to failure **kisi aur problem jaisa dikhta hai**:

### 5.1 `pilot.cni.enabled: true`
```
violates PodSecurity "restricted:latest": unrestricted capabilities
(container "istio-init" must not include "NET_ADMIN", "NET_RAW" ...)
```
Injector ko pata nahi tha ki Istio CNI hai, to privileged `istio-init` inject kar raha tha.
Kubeflow namespaces par PodSecurity `restricted` hai → **har Deployment fail**.

> **Trap:** `istio_cni.enabled: true` bhi chahiye par **akela kaafi nahi**. Injection template
> specifically `.Values.pilot.cni.enabled` padhta hai. Dono set karne padte hain.

Sahi hone par init container ka naam `istio-validation` ho jaata hai (unprivileged).

### 5.2 `global.proxy.seccompProfile.type: RuntimeDefault`
```
violates PodSecurity "restricted:latest": seccompProfile
(containers "istio-validation", "istio-proxy" must set securityContext.seccompProfile.type)
```
Pehla fix karne ke baad ye agla error aata hai.

### 5.3 `meshConfig.extensionProviders` — oauth2-proxy
Kubeflow ki AuthorizationPolicies `action: CUSTOM` use karti hain jo is provider ko naam se
reference karti hain. Missing ho to saare authenticated routes tut jaate hain.

Saath me `PILOT_JWT_PUB_KEY_REFRESH_INTERVAL: "1m"` (default 20m se login loop hota hai).

### 5.4 ⭐ Ingress gateway ka ServiceAccount naam — sabse chupa hua
```yaml
serviceAccount:
  name: istio-ingressgateway-service-account
```
Kubeflow ki har app ki AuthorizationPolicy sirf ye mTLS principal allow karti hai:
```
cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account
```
Istio ka Helm gateway chart SA ka naam **release name** se banata hai → `istio-ingressgateway`.
Naam match nahi → principal match nahi → natija:

> Login **successful**, saare pods **healthy**, saare pod-checks **pass** — lekin har single UI
> `403 RBAC: access denied`.

Debug mushkil isliye tha ki gateway ka access log `via_upstream` dikhata hai (gateway ne aage
bhej diya); deny actually **destination pod ke sidecar** par ho raha tha.

**Yahi wajah hai ki `99-verify.sh` sirf pods check nahi karti — wo asli login karke dashboard
aur KFAM API call karti hai.** Sirf functional test hi is bug ko pakad sakta hai.

---

## 6. Do aur bugs jo mile

### 6.1 KServe chart CRD ko upgrade par delete kar deta hai
`kserve-crd` chart me `ClusterStorageContainer` CRD `lookup` se guard hai:
```gotemplate
{{- $existing := lookup "apiextensions.k8s.io/v1" "CustomResourceDefinition" "" "clusterstoragecontainers.serving.kserve.io" -}}
{{- if not $existing }} ... {{- end }}
```
- **Install:** CRD nahi hai → render hota hai → ban jaata hai ✅
- **Upgrade:** CRD hai → guard kuch render nahi karta → **Helm use "removed resource" samajh kar
  DELETE kar deta hai** ❌ → `kserve-resources` turant fail

`03-helm-apps.sh` ab release maujood hone par upgrade skip karti hai aur CRD missing ho to
chart ki `files/` se direct apply kar deti hai.

### 6.2 Duplicate ReplicaSets se rollout deadlock
Jab pehla rollout chal raha ho aur `kubectl rollout restart` chala diya jaaye, to har Deployment
ke do active ReplicaSet ban jaate hain (43 RS vs 27 Deployments dekha gaya). Purane RS ke pods RAM
pakde rehte hain, naye pods ko RAM milti nahi — tight cluster par **permanent deadlock**.

Fix: har Deployment ka sirf latest revision rakhna (script troubleshooting doc me hai).

---

## 7. Verification results — sab pass

`make verify` ke 17 checks:

```
pass  all nodes Ready
pass  all Helm releases deployed
pass  istio-system: all pods healthy (4 pods)
pass  cert-manager: all pods healthy (3 pods)
pass  local-path-storage: all pods healthy (1 pods)
pass  auth: all pods healthy (2 pods)
pass  oauth2-proxy: all pods healthy (2 pods)
pass  kubeflow: all pods healthy (34 pods)
pass  all PVCs Bound
pass  Kubeflow Gateway present
pass  oauth2-proxy ext-authz provider present in mesh config
pass  http://192.168.56.134:31380 responded HTTP 403 (auth challenge served)
pass  auth flow reaches the Dex login page
pass  logged in as user@example.com; Central Dashboard returned 200
pass  KFAM API returns the user's namespace (kubeflow-user-example-com)
pass  profile kubeflow-user-example-com exists
pass  profile namespace created
```

### Functional tests (pods dekhne se aage)

| Test | Result |
|---|---|
| Full OIDC login (dex → oauth2-proxy → session cookie) | ✅ |
| Central Dashboard `/` | HTTP 200, title "Kubeflow Central Dashboard" |
| `/pipeline/` `/jupyter/` `/katib/` `/kserve-endpoints/` `/volumes/` `/tensorboards/` | sab HTTP 200 |
| KFAM API `/api/workgroup/env-info` | user + namespace + role=owner correctly returned |
| **KFP API write** — experiment create + delete | ✅ HTTP 200, `experiment_id` mila |
| Dashboard menu me KServe Endpoints entry | ✅ Helm-installed component integrate hua |
| Idempotency — `make prereqs/infra/apps` dobara | ✅ clean re-run |

### Final resource usage

| Node | CPU requests | Memory requests |
|---|---|---|
| k8s-cp-0 | 1582m (19%) | 3594Mi (49%) |
| k8s-w-0 | 1240m (15%) | 3368Mi (46%) |

PVCs: `mysql-pv-claim` 20Gi · `seaweedfs-pvc` 20Gi · `katib-mysql` 10Gi — sab Bound.
CRDs installed: 97.

---

## 8. Environment observations

- **Internet ~1.2 MB/s (≈9 Mbps)** on the VMs. Kubeflow kai GB images pull karta hai, isliye
  pehla install 40-60 min laga. `containerd` pulls serialize karta hai — ek image ka log
  `988ms (15m25s including waiting)` dikha, yaani queue me atka tha, download slow nahi tha.
- **Nodes par IPv6 default route nahi hai**, par `pkg-containers.githubusercontent.com` IPv6
  pehle resolve karta hai. Fast-fail hota hai isliye blocker nahi bana, par worth knowing.
- Worker node bhaari image pulling ke dauraan ek baar `NotReady` flap hua (load average 7.5),
  apne aap recover ho gaya.

---

## 9. Known limitations (agar dobara deploy karein)

1. **Production setup nahi hai** — control-plane untainted, HTTP (TLS nahi), default credentials,
   node-local storage (node gaya to data gaya).
2. **Scale-to-zero nahi** — KServe RawDeployment mode me hai (Knative disabled).
3. **RAM tight** — ~9Gi request vs ~14.4Gi allocatable. Trim order: Spark → Trainer → Katib.
4. **Backup nahi hai** — Pipelines ka MySQL aur SeaweedFS local disk par.
5. **RWX support nahi** — `local-path` sirf ReadWriteOnce.
6. Dashboard me **"Model Registry" link 404** degi (Hub disabled).

---

## 10. Teardown (2026-08-12)

Deployment verify hone ke baad cluster ko baseline par wapas laaya gaya:

```bash
bash scripts/98-uninstall.sh --yes --revert-nodes
```

**Kya hataya gaya:** 10 Helm releases · namespaces `kubeflow`, `kubeflow-user-example-com`,
`auth`, `oauth2-proxy`, `istio-system`, `cert-manager`, `local-path-storage` ·
**40 CRDs** · 3 PVs aur unka saara data · dono nodes par `/opt/local-path-provisioner/*`.

**Node changes revert:** control-plane par `NoSchedule` taint wapas laga, aur
`/etc/sysctl.d/99-kubeflow.conf` dono nodes se hata.

### Post-teardown verification — baseline se exact match

| Check | Baseline (deploy se pehle) | Teardown ke baad | |
|---|---|---|---|
| Namespaces | 6 (calico-system, default, kube-node-lease, kube-public, kube-system, tigera-operator) | wahi 6 | ✅ |
| Helm releases | 0 | 0 | ✅ |
| StorageClass | koi nahi | koi nahi | ✅ |
| PV / PVC | 0 / 0 | 0 / 0 | ✅ |
| CRDs | 32 (22 Calico + 9 tigera + 1 policy.networking) | wahi 32 | ✅ |
| control-plane taint | `NoSchedule` | `NoSchedule` | ✅ |
| Cluster pods | sab Running | 18 Running | ✅ |

Calico CNI ko chhua tak nahi gaya — CRD sweep me sirf wahi API groups delete kiye gaye jo is
repo ne introduce kiye the (`OUR_CRD_GROUPS` list `98-uninstall.sh` me hai).

### Image cache bhi hataya gaya

```bash
for h in 192.168.56.134 192.168.56.135; do ssh root@$h 'crictl rmi --prune'; done
```

`crictl rmi --prune` sirf **unused** images hatata hai, isliye running cluster containers ki
images (Calico, kube-system, kube-vip) safe rahi. Worker par kuch images `DeadlineExceeded`
se timeout hui thi (slow disk I/O) — command dobara chalane se clear ho gayi.

| Node | Images | containerd | Disk used | Disk free |
|---|---|---|---|---|
| k8s-cp-0 | 50 → **17** | 15G → **2.1G** | 29G → **16G** | 65G → **77G** |
| k8s-w-0 | 46 → **7** | 11G → **883M** | 22G → **13G** | 71G → **81G** |

**Total ~22GB reclaim hua.** Har Kubeflow / Istio / cert-manager / KServe image chali gayi;
sirf cluster infrastructure bachi:

- **k8s-cp-0 (17):** kube-apiserver, etcd, kube-controller-manager, kube-scheduler, kube-proxy,
  coredns, pause, kube-vip, Calico ×9, tigera-operator
- **k8s-w-0 (7):** Calico ×5, kube-proxy, pause

**Cluster health prune ke baad:** dono nodes `Ready`, saare 18 pods `Running`, API responsive.
Prune ke dauraan kisi container ne restart nahi kiya (sabse purana running container 93 min ka
tha, prune ke waqt se kaafi pehle ka).

> ⚠️ Cache khali hone ki wajah se agla `make all` phir se **40-60 minute** lega — saari images
> dobara download hongi ~1.2 MB/s par.

---

## 11. Dobara deploy karna ho to

```bash
cd /root/kube-flow
make all        # prereqs → infra → core → apps → verify
```

Saare phases idempotent hain. Config sirf `cluster.env` me hai — IPs, versions, credentials,
aur `INSTALL_*` feature flags.

**Access:** http://192.168.56.134:31380 · `user@example.com` / `12341234`
**Namespace:** `kubeflow-user-example-com`

⚠️ Kisi bhi shared ya internet-facing cluster par default password turant badaliye.

### Reference

- [`kubeflow-deployment-guide.md`](kubeflow-deployment-guide.md) — poora walkthrough
- [`troubleshooting.md`](troubleshooting.md) — 14 sections, har gotcha ke saath
