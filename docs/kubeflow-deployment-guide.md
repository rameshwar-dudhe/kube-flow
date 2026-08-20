# Kubeflow Deployment Guide (Helm-first Hybrid)

**Cluster:** `192.168.56.134` (Kubernetes v1.36.3)
**Kubeflow:** `26.03.1`
**Approach:** Helm-first hybrid (Helm + kustomize)

---

## 1. Intro — hum kya bana rahe hain

Is guide me hum ek 2-node Kubernetes cluster par **poora Kubeflow platform** deploy karenge,
maximum cheezein **Helm** se. Sab kuch scripted hai, isliye ek command me chalta hai:

```bash
cd /root/kube-flow
make all
```

Iske baad browser me **http://192.168.56.134:31380** kholiye aur
`user@example.com` / `12341234` se login kar lijiye.

---

## 2. Sabse important baat — pure Helm possible nahi hai

Ye baat pehle samajh lena zaroori hai, warna aap galat direction me time waste karenge.

**Kubeflow ka koi single Helm chart exist nahi karta.** Ye Kubeflow ki design choice hai —
Helm me dependency sequencing ki woh capability nahi hai jo Kubeflow ke ~30 components ko sahi
order me deploy karne ke liye chahiye.

Aapko internet par jo options milenge, unki asli haalat ye hai:

| Option | Status | Verdict |
|---|---|---|
| **deployKF** | Last commit **May 2024**. Kubeflow 1.8-era components par pinned. | ❌ Dead. K8s 1.36 par chalega hi nahi. |
| **Official `experimental/helm/charts`** | Sirf **3 components** (hub, katib, kserve-models-web-app). Katib chart v0.16.0 hai jabki distribution ko v0.19.0 chahiye. | ⚠️ Incomplete + version mismatch |
| **Official kustomize manifests** | Poora platform, K8s 1.36 supported, actively maintained | ✅ Supported, par Helm nahi |
| **Per-component official charts** | KServe, Trainer, Spark Operator ke real charts hain | ✅ Use karenge |

> **Kubeflow Pipelines ka to koi Helm chart hai hi nahi** — aur wahi to Kubeflow ka dil hai.

**Isliye hybrid approach:** jahan genuine aur version-matched Helm chart hai wahan **Helm**,
aur sirf wahan **kustomize** jahan koi chart hai hi nahi.

### Kya Helm se, kya kustomize se

| Helm se install | Version | kustomize se install | Kyun Helm nahi |
|---|---|---|---|
| local-path-provisioner | v0.0.37 | dex | Kubeflow-specific OIDC config |
| cert-manager | v1.20.2 | oauth2-proxy | Kubeflow-specific OIDC config |
| Istio (base/istiod/cni/gateway) | 1.30.1 | **Kubeflow Pipelines** | koi chart nahi hai |
| KServe | v0.18.0 | Central Dashboard + Profiles | koi chart nahi hai |
| Kubeflow Trainer | 2.2.0 | Notebooks v1 | koi chart nahi hai |
| Spark Operator | 2.5.0 | Katib | chart v0.16.0, chahiye v0.19.0 |
| | | KServe models web app | koi chart nahi hai |

Ye saari versions `cluster.env` me pinned hain aur Kubeflow 26.03.1 ke saath exactly match karti hain.
**Inhe randomly mat badaliye** — mismatch se dashboard integration tut jaata hai.

---

## 3. Cluster ki baseline aur constraints

Deploy karne se pehle cluster ka jo actual state tha:

| Cheez | Value | Problem? |
|---|---|---|
| Kubernetes | v1.36.3, containerd 2.3.3, Ubuntu 26.04 | ✅ 26.03.1 isko support karta hai |
| Nodes | `k8s-cp-0` (192.168.56.134), `k8s-w-0` (192.168.56.135) | — |
| Per node | 8 CPU, 7.2Gi RAM, 98G disk | ⚠️ RAM tight hai |
| CNI | Calico (tigera-operator) | ✅ Istio CNI ke saath compatible |
| **StorageClass** | **koi nahi** | ❌ Blocker — Kubeflow ko ~45GB PVC chahiye |
| **LoadBalancer** | **koi nahi** | ❌ NodePort use karna padega |
| control-plane taint | `NoSchedule` laga tha | ❌ Sirf 7.2Gi schedulable tha |
| helm / kubectl | installed hi nahi the | — |

### RAM ka hisaab

Kubeflow 26.03.1 ka poora footprint: **4380m CPU / 12341Mi RAM / 65GB PVC**.

Humare paas control-plane untaint karne ke baad ~14.4Gi hai. 12.3Gi vs 14.4Gi bilkul edge par hai,
isliye kuch optional components band kiye:

| Component | Bachat | Kyun band kiya |
|---|---|---|
| Kubeflow Hub | 2112Mi + 20GB PVC | Optional model registry |
| Knative | 1038Mi + 1450m CPU | Sirf KServe Serverless ke liye. Hum RawDeployment use kar rahe hain |
| training-operator v1.9.2 | 25Mi | Legacy — Trainer v2.2.0 ne replace kar diya |

**Trimmed budget: ~9.0Gi RAM / ~45GB PVC** — 14.4Gi me aaram se fit ho jaata hai.

Ye sab `cluster.env` ke `INSTALL_*` flags se wapas on kiye ja sakte hain.

---

## 4. Repo ka structure

```
/root/kube-flow/
├── cluster.env        <- SAARI configuration yahan (IP, versions, password, flags)
├── Makefile           <- make prereqs|infra|core|apps|verify|status|uninstall
├── scripts/
│   ├── lib.sh              common helpers (retry, wait, logging)
│   ├── 00-prereqs.sh       Phase 0
│   ├── 01-helm-infra.sh    Phase 1
│   ├── 02-kubeflow-core.sh Phase 2
│   ├── 03-helm-apps.sh     Phase 3
│   ├── 98-uninstall.sh     cleanup
│   └── 99-verify.sh        Phase 4
├── values/            <- har chart ka apna values file
├── docs/              <- ye guide + troubleshooting
└── .cache/            <- cloned manifests, rendered YAML (delete kar sakte hain)
```

Saare scripts **idempotent** hain — dobara chalane se kuch nahi tootega.

---

## 5. Phase 0 — Prerequisites

```bash
make prereqs
```

Ye 4 kaam karta hai:

**a) CLI tools install karta hai** (`/usr/local/bin` me):
- `kubectl` v1.36.3 — cluster se match karta hua
- `helm` v3.21.3 — **Helm 4 jaan-bujhkar nahi**. Helm 4 aa chuka hai par ye saare charts
  Helm 3 ke liye likhe gaye hain
- `kustomize` v5.8.1

**b) kubeconfig laata hai** control-plane se, aur server address ko `https://192.168.56.134:6443`
par set karta hai. Script check bhi karti hai ki API server ka certificate us IP ko cover karta hai
ya nahi — agar nahi, to saaf error deti hai.

**c) control-plane ka taint hatata hai:**
```bash
kubectl taint nodes k8s-cp-0 node-role.kubernetes.io/control-plane-
```
> ⚠️ Iska matlab Kubeflow ke workloads etcd/apiserver ke saath same node par chalenge.
> Lab ke liye theek hai, **production pattern nahi hai**. Production me alag worker nodes rakhiye.

**d) inotify limits badhata hai** dono nodes par (`/etc/sysctl.d/99-kubeflow.conf`).
Istio CNI aur Notebooks ko iski zaroorat padti hai.

**Expected output ke end me:**
```
NAME       TAINTS
k8s-cp-0   <none>
k8s-w-0    <none>
```

---

## 6. Phase 1 — Infrastructure (100% Helm)

```bash
make infra
```

### a) local-path-provisioner — StorageClass

Cluster me koi StorageClass thi hi nahi, isliye har PVC hamesha `Pending` rehti. Ye chart
`local-path` naam ki **default** StorageClass banata hai jo node ki local disk
(`/opt/local-path-provisioner`) use karti hai.

```
NAME                   PROVISIONER                            RECLAIMPOLICY   VOLUMEBINDINGMODE
local-path (default)   cluster.local/local-path-provisioner   Delete          WaitForFirstConsumer
```

> `WaitForFirstConsumer` ka matlab: PVC tab tak `Pending` dikhegi jab tak koi pod use mount na kare.
> **Ye normal hai**, error nahi.

### b) cert-manager v1.20.2

Kubeflow ke bahut saare components apne admission webhooks ke liye certificates cert-manager
se lete hain.

### c) Istio 1.30.1 — sabse nazuk hissa

Chaar charts, isi order me: `base` → `istiod` → `cni` → `gateway`.

Gateway ka Helm **release name `istio-ingressgateway` hona hi chahiye**, kyunki chart usse
`istio: ingressgateway` label banata hai — aur Kubeflow ka Gateway resource usi label par
select karta hai. Naam badla to routing chup-chaap tut jayegi.

Gateway NodePort par expose hota hai (LoadBalancer nahi hai na):
```
istio-ingressgateway   NodePort   80:31380/TCP, 443:31390/TCP
```

### ⚠️ Chaar critical settings — inke bina Kubeflow chalega hi nahi

Kyunki hum Istio ko Helm se laga rahe hain (Kubeflow ke kustomize overlay se nahi), chaar cheezein
manually reproduce karni padti hain. Ye is deployment ka **sabse bada gotcha** hai — aur teeno me
se koi bhi miss ho to failure aisa dikhta hai jaise koi aur problem ho:

**1. `pilot.cni.enabled: true`**
```yaml
pilot:
  cni:
    enabled: true
```
Kubeflow ke namespaces par PodSecurity `restricted` laga hota hai. Agar injector ko pata na ho ki
Istio CNI use ho raha hai, to wo har pod me privileged `istio-init` container daal dega, aur
kubeflow namespace ki **har single Deployment** ye error deke fail hogi:
```
violates PodSecurity "restricted:latest": unrestricted capabilities
(container "istio-init" must not include "NET_ADMIN", "NET_RAW" ...)
```
Sahi flag lagne par injector `istio-init` ki jagah unprivileged **`istio-validation`** container
inject karta hai.

> **Trap:** `istio_cni.enabled: true` bhi set karna padta hai, par **wo akela kaafi nahi hai**.
> Injection template specifically `.Values.pilot.cni.enabled` padhta hai. Dono set kijiye.

**2. `global.proxy.seccompProfile.type: RuntimeDefault`**
```yaml
global:
  proxy:
    seccompProfile:
      type: RuntimeDefault
```
Upar wala fix karne ke baad agla error aata hai:
```
violates PodSecurity "restricted:latest": seccompProfile
(pod or containers "istio-validation", "istio-proxy" must set
 securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```
Injected sidecars ko seccomp profile declare karna hi padta hai.

**3. `oauth2-proxy` extensionProvider**
```yaml
meshConfig:
  extensionProviders:
    - name: oauth2-proxy
      envoyExtAuthzHttp:
        service: oauth2-proxy.oauth2-proxy.svc.cluster.local
        port: 80
        ...
```
Kubeflow ki AuthorizationPolicies `action: CUSTOM` use karti hain jo is provider ko naam se
reference karti hain. Agar mesh config me ye provider na ho, to **saare authenticated routes tut
jaate hain** — login page bhi theek se kaam nahi karega.

Saath me `PILOT_JWT_PUB_KEY_REFRESH_INTERVAL: "1m"` bhi set hai. Default 20 minutes hai, aur
fresh install me istiod dex se pehle up ho jaata hai, placeholder JWKS cache kar leta hai, aur
tab tak login fail hota rehta hai. 1m se recovery fast ho jaati hai.

**4. Ingress gateway ka ServiceAccount naam** — `values/istio-ingressgateway.yaml`:
```yaml
serviceAccount:
  create: true
  name: istio-ingressgateway-service-account
```

Ye sabse **chupa hua** trap hai. Kubeflow ki har application ke saath ek AuthorizationPolicy aati
hai jo sirf is mTLS principal ko allow karti hai:
```
cluster.local/ns/istio-system/sa/istio-ingressgateway-service-account
```
Istio ka Helm `gateway` chart ServiceAccount ka naam **release name** se banata hai — yaani
`istio-ingressgateway`. Naam match nahi karega, principal match nahi karega, aur natija:

> Login **successfully** ho jayega, saare pods **healthy** dikhenge, `make verify` ke saare pod
> checks **pass** honge — lekin har single UI `403 RBAC: access denied` dega.

Debug karna mushkil hai kyunki gateway ka access log `via_upstream` dikhata hai (matlab gateway ne
request aage bhej di); deny actually **destination pod ke sidecar** par ho raha hota hai.

Isi wajah se `99-verify.sh` sirf pods check nahi karti — wo **asli login karke** dashboard aur
KFAM API call karti hai. Sirf yahi test is bug ko pakad sakta hai.

---

## 7. Phase 2 — Kubeflow core (kustomize)

```bash
make core
```

Ye phase wo sab deploy karta hai jiska koi Helm chart nahi hai.

**Steps:**

1. `kubeflow/community-distribution` repo ko tag `26.03.1` par clone karta hai (`.cache/` me)

2. **Istio ke 3 standalone CRs apply karta hai.** Kubeflow ka `istio-install/base` folder Istio ke
   install ke saath-saath ye resources bhi rakhta hai, jo Istio ke Helm charts me nahi aate:
   - `gateway.yaml` — wo Gateway jispe saari Kubeflow VirtualServices bind hoti hain
   - `gateway_authorizationpolicy.yaml` — ingress gateway ke liye ALLOW policy
   - `deny_all_authorizationpolicy.yaml` — mesh-wide default-deny

3. **Hybrid kustomization generate karta hai** — `example/kustomization.yaml` ki copy, par usme se
   wo sab hata ke jo Helm se laga chuke hain. `cluster.env` ke flags isko control karte hain.

4. **Apply karta hai retry loop ke saath.** Ye zaroori hai — Kubeflow khud document karta hai ki
   pehli baar `kubectl apply` fail hoga, kyunki CR apne CRD se pehle create nahi ho sakta.
   Script 15 baar tak, 20s gap ke saath try karti hai. Beech me ye errors dikhna **normal hai**:
   ```
   no matches for kind "Profile" in version "kubeflow.org/v1beta1"
   ensure CRDs are installed first
   ```

5. **`sidecar-prune-egress.yaml` last me apply hota hai** — isme jo Sidecar resources hain wo
   `kubeflow` namespace me rehte hain, jo step 4 se pehle exist hi nahi karta.

**Kya install hota hai:** dex, oauth2-proxy, kubeflow namespace + roles, Kubeflow Pipelines
(KFP 2.16.1 + SeaweedFS + MySQL), Central Dashboard, profile-controller, Notebooks v1, Katib
v0.19.0, aur default user profile.

Ye phase sabse lamba hai — **15–25 minute** lagte hain, zyadatar image pulling me.

---

## 8. Phase 3 — Applications (Helm)

```bash
make apps
```

### KServe v0.18.0
```bash
helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd --version v0.18.0 -n kubeflow
helm upgrade --install kserve oci://ghcr.io/kserve/charts/kserve-resources --version v0.18.0 -n kubeflow
```

`kubeflow` namespace me isliye jaata hai taaki Kubeflow ke apne overlay se match kare. Fayda ye
hai ki chart har reference `.Release.Namespace` se banata hai, isliye cert-manager ke
`inject-ca-from` annotations apne aap consistent rehte hain — Kubeflow ke kustomize overlay ko jo
annotation-rewriting patch lagana padta hai, wo yahan zaroori nahi.

**RawDeployment mode** use kar rahe hain (`kserve.controller.deploymentMode: RawDeployment`):
- Knative ki zaroorat nahi → 1450m CPU + 1038Mi RAM bachta hai
- **Trade-off:** InferenceServices me scale-to-zero nahi milega

### Kubeflow Trainer 2.2.0
```bash
helm upgrade --install kubeflow-trainer oci://ghcr.io/kubeflow/charts/kubeflow-trainer --version 2.2.0 -n kubeflow
```

### Spark Operator 2.5.0
Ye kisi Helm repo ya OCI registry par publish nahi hota; GitHub release ka tarball hi supported
artifact hai:
```bash
helm upgrade --install spark-operator \
  https://github.com/kubeflow/spark-operator/releases/download/v2.5.0/spark-operator-2.5.0.tgz -n kubeflow
```

### KServe models web app
Iska koi chart nahi hai — kustomize se aata hai. Yahi Central Dashboard ka **Endpoints** section
banata hai.

---

## 9. Phase 4 — Verify

```bash
make verify
```

Ye check karta hai: nodes Ready, saari Helm releases `deployed`, har namespace ke pods healthy,
PVCs `Bound`, Gateway maujood, mesh config me oauth2-proxy provider hai, NodePort HTTP respond kar
raha hai, aur user profile ban gaya.

Success par:
```
================================================
 Kubeflow is up.
================================================

  URL       http://192.168.56.134:31380
  Username  user@example.com
  Password  12341234

  Namespace kubeflow-user-example-com
```

---

## 10. Access aur login

| Cheez | Value |
|---|---|
| URL | http://192.168.56.134:31380 |
| Username | `user@example.com` |
| Password | `12341234` |
| Namespace | `kubeflow-user-example-com` |

### Password badalna

Dex bcrypt hash use karta hai. Naya hash banaiye:
```bash
htpasswd -bnBC 12 "" 'NayaPassword' | tr -d ':\n'
```
Phir `.cache/community-distribution/common/dex/base/dex-passwords.yaml` me `DEX_USER_PASSWORD`
replace kar ke:
```bash
kubectl -n auth rollout restart deploy dex
```

> ⚠️ Ye default credentials **sirf lab ke liye** hain. Kisi bhi shared ya internet-facing cluster par
> password turant badaliye.

### Laptop se access (agar NodePort reachable nahi)
```bash
kubectl -n istio-system port-forward svc/istio-ingressgateway 8080:80
# phir http://localhost:8080
```

---

## 11. Version matrix

| Component | Version | Kaise |
|---|---|---|
| Kubernetes | v1.36.3 | pehle se |
| Kubeflow distribution | 26.03.1 | kustomize |
| Kubeflow Pipelines | 2.16.1 | kustomize |
| Central Dashboard | v2.0.0 | kustomize |
| Notebooks | v1.11.0 | kustomize |
| Katib | v0.19.0 | kustomize |
| dex | 2.45.1 | kustomize |
| oauth2-proxy | 7.15.2 | kustomize |
| Istio | 1.30.1 | **Helm** |
| cert-manager | v1.20.2 | **Helm** |
| KServe | v0.18.0 | **Helm** |
| Kubeflow Trainer | 2.2.0 | **Helm** |
| Spark Operator | 2.5.0 | **Helm** |
| local-path-provisioner | v0.0.37 | **Helm** |

---

## 12. Day-2 operations

### Roz ke commands
```bash
make status     # sirf unhealthy pods + helm releases + PVCs
make verify     # poora health check
make logs       # Central Dashboard ke logs
```

### Helm component upgrade
`cluster.env` me version badliye, phir:
```bash
make apps       # ya infra, jaisa applicable ho
```

### Component ko Helm se kustomize par switch karna
Agar koi Helm-installed component dashboard me nahi dikh raha ya theek se behave nahi kar raha:
```bash
# cluster.env me edit kijiye
INSTALL_KSERVE="kustomize"

helm uninstall kserve kserve-crd -n kubeflow
make core && make apps
```

### Band kiye gaye components wapas on karna
```bash
# cluster.env
INSTALL_KNATIVE="kustomize"   # KServe Serverless / scale-to-zero ke liye
INSTALL_HUB="kustomize"       # Model registry

make core
```
> Pehle RAM check kar lijiye: `kubectl top nodes`

### Uninstall
```bash
make uninstall    # confirmation maangta hai; PV ka data delete ho jayega
```

---

## 13. Known limitations

1. **Ye production setup nahi hai.** Control-plane untainted hai, HTTP hai (TLS nahi), default
   credentials hain, aur storage node-local hai (node gaya to data gaya).
2. **Scale-to-zero nahi** — KServe RawDeployment mode me hai.
3. **RAM tight hai.** ~9Gi request vs ~14.4Gi allocatable. Heavy pipelines chalane par pods
   `Pending` ja sakte hain. Trim order: Spark → Trainer → Katib.
4. **Backup configured nahi hai.** Pipelines ka MySQL aur SeaweedFS local disk par hain.
5. `local-path` storage me **ReadWriteMany support nahi** hai — kuch multi-pod workloads isse
   nahi chal payenge.
6. Dashboard me **"Model Registry" menu entry 404 degi**, kyunki Hub band hai
   (`INSTALL_HUB="off"`). Chahiye to `cluster.env` me on kar dijiye.
7. In VMs par **internet ~1.2 MB/s** hai. Kubeflow kai GB images pull karta hai, isliye pehla
   `make all` **40-60 minute** le sakta hai. Pods ka `PodInitializing` par lamba rukna normal hai —
   `kubectl describe pod` me "Pulling image" dikhega. Ye galti nahi, bas slow network hai.

---

## 14. Aage kya

- TLS lagaiye (cert-manager already installed hai — self-signed issuer bana lijiye)
- Dex ko asli identity provider se jodiye (LDAP / GitHub / OIDC)
- Zyada users ke liye aur Profiles banaiye
- Agar VMs ki RAM 16Gi+ kar sakte hain to Knative aur Hub wapas on kar dijiye

Problem aaye to → [`troubleshooting.md`](troubleshooting.md)
