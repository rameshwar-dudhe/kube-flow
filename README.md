# Kubeflow on Kubernetes — Helm-first hybrid deployment

Deploys **Kubeflow 26.03.1** onto the 2-node cluster at `192.168.56.134` (Kubernetes v1.36.3).

```bash
make all        # prereqs -> infra -> core -> apps -> verify
```

Then open **http://192.168.56.134:31380** and log in with `user@example.com` / `12341234`.

## Why "hybrid" and not pure Helm

There is no single Helm chart that installs Kubeflow, and there is no longer any distribution
that offers one. deployKF — the only project that ever did — has been unmaintained since
May 2024 and does not run on Kubernetes 1.36. The official distribution
(`kubeflow/community-distribution`) is kustomize-based; its `experimental/helm/charts` directory
covers only 3 components, and **Kubeflow Pipelines has no Helm chart at all**.

So this repo uses Helm for every layer that has a genuine, version-matched chart, and kustomize
only where none exists:

| Installed with Helm | Version | Installed with kustomize | Why |
|---|---|---|---|
| local-path-provisioner | v0.0.37 | dex | Kubeflow-specific OIDC config |
| cert-manager | v1.20.2 | oauth2-proxy | Kubeflow-specific OIDC config |
| Istio base/istiod/cni/gateway | 1.30.1 | Kubeflow Pipelines | no chart exists |
| KServe | v0.18.0 | Central Dashboard + Profiles | no chart exists |
| Kubeflow Trainer | 2.2.0 | Notebooks v1 | no chart exists |
| Spark Operator | 2.5.0 | Katib | chart is v0.16.0, needs v0.19.0 |
| | | KServe models web app | no chart exists |

Every version above is pinned in `cluster.env` to match Kubeflow 26.03.1.

## Layout

```
cluster.env      all configuration - IPs, versions, credentials, feature flags
Makefile         make prereqs | infra | core | apps | verify | status | uninstall
scripts/         one script per phase, all idempotent
values/          one Helm values file per chart
docs/            deployment guide + troubleshooting (Hinglish)
.cache/          cloned manifests and rendered YAML (gitignored, safe to delete)
```

## Phases

| Command | Does |
|---|---|
| `make prereqs` | Installs kubectl/helm/kustomize, fetches kubeconfig, untaints the control-plane, raises inotify limits |
| `make infra` | Helm: StorageClass, cert-manager, Istio + NodePort gateway |
| `make core` | kustomize: dex, oauth2-proxy, Pipelines, Dashboard, Notebooks, Katib, user profile |
| `make apps` | Helm: KServe, Trainer, Spark Operator |
| `make verify` | Health checks; prints the URL and credentials |

## Cluster-specific notes

- The cluster shipped with **no StorageClass**; `make infra` installs local-path-provisioner and
  marks it default. Kubeflow needs ~45GB of RWO volumes.
- There is **no LoadBalancer**, so the Istio gateway is exposed as **NodePort 31380**.
- The control-plane taint is **removed** so both nodes can run workloads. With ~7.2Gi per node,
  a single worker cannot hold Kubeflow. This is a lab pattern, not a production one.
- Knative, Kubeflow Hub and the legacy training-operator are **disabled** to fit the RAM budget.
  Re-enable them via the `INSTALL_*` flags in `cluster.env`.

## Docs

- [`docs/kubeflow-deployment-guide.md`](docs/kubeflow-deployment-guide.md) — full walkthrough
- [`docs/troubleshooting.md`](docs/troubleshooting.md) — common failures and fixes
