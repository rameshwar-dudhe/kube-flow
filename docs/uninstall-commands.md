# Uninstall - commands reference

Every command involved in tearing down this deployment, at two levels: what you
type, and what `scripts/98-uninstall.sh` runs underneath.

Recorded from the teardown run on 2026-08-12 (exit code 0, no warnings).

## What you type

```bash
make uninstall                                  # interactive, prompts for 'yes'
make uninstall ARGS="--yes"                     # no prompt, leaves node changes in place
make uninstall ARGS="--yes --revert-nodes"      # no prompt, also re-taints CP + drops sysctl
```

Quotes around `ARGS` are required. Unquoted, `make uninstall ARGS=--yes --revert-nodes`
hands `--revert-nodes` to make itself, which fails with `unrecognized option`.
Same reason `make uninstall --yes --revert-nodes` never worked: make parses
anything leading with `-` as its own option, so the flags never reach the script.

The flag is `--revert-nodes`, plural. Anything else hits
`die "unknown argument"` in the arg loop and aborts.

Equivalent direct invocation, bypassing make:

```bash
bash scripts/98-uninstall.sh --yes --revert-nodes
```

Useful alongside it:

```bash
make status     # kubectl get pods -A -o wide | grep -vE '\s(Running|Completed)\s'
                # helm list -A
                # kubectl get pvc -A
make clean      # rm -rf .cache   (local cache only, touches no cluster state)
```

## What the script runs

Order is load-bearing: CRs before CRDs, PVCs before the provisioner (otherwise
volumes are never reclaimed), apps before Istio.

### 1/7 Helm applications

```bash
helm uninstall spark-operator     -n kubeflow --wait --timeout 5m
helm uninstall kubeflow-trainer   -n kubeflow --wait --timeout 5m
helm uninstall kserve             -n kubeflow --wait --timeout 5m
helm uninstall kserve-crd         -n kubeflow --wait --timeout 5m
```

### 2/7 kustomize-managed Kubeflow core

```bash
kubectl delete -f .cache/kubeflow-core.yaml --ignore-not-found --wait=false --timeout=60s
```

Falls back to plain namespace deletion if the rendered manifest was never cached.

### 3/7 PVCs

```bash
kubectl delete pvc --all -n kubeflow --ignore-not-found --timeout=120s
```

Then polls `kubectl get pv` for up to 60s so local-path's reclaim jobs can clear
the on-disk directories.

### 4/7 Namespaces

```bash
kubectl delete namespace kubeflow           --ignore-not-found --wait=false
kubectl delete namespace "$KF_PROFILE_NAME" --ignore-not-found --wait=false
kubectl delete namespace auth               --ignore-not-found --wait=false
kubectl delete namespace oauth2-proxy       --ignore-not-found --wait=false
```

Then waits up to 3 min for them to finish terminating.

### 5/7 Helm infrastructure

```bash
helm uninstall istio-ingressgateway   -n istio-system
helm uninstall istio-cni              -n istio-system
helm uninstall istiod                 -n istio-system
helm uninstall istio-base             -n istio-system
helm uninstall cert-manager           -n cert-manager
helm uninstall local-path-provisioner -n local-path-storage

kubectl delete namespace istio-system cert-manager local-path-storage --ignore-not-found --wait=false
kubectl delete pv --all --ignore-not-found --wait=false
```

### 6/7 CRD sweep

```bash
kubectl delete crd <name> --ignore-not-found --wait=false --timeout=30s
```

Run once per CRD whose name ends in one of the groups this repo introduced
(`OUR_CRD_GROUPS` in the script): kubeflow.org, trainer.kubeflow.org,
tensorboard.kubeflow.org, serving.kserve.io, the five istio.io groups,
cert-manager.io, acme.cert-manager.io, dex.coreos.com, argoproj.io,
metacontroller.k8s.io, sparkoperator.k8s.io, jobset.x-k8s.io.

Calico's `crd.projectcalico.org` / `operator.tigera.io` and the cluster's own
`policy.networking.k8s.io` are never touched. The script then counts the
surviving Calico CRDs and warns if fewer than 30 remain.

### 7/7 Volume data on nodes

```bash
ssh <node> 'rm -rf /opt/local-path-provisioner/*'
```

Run against `$CP_IP` and `$WORKER_IP`. An unreachable node is warned about and
skipped, not treated as fatal.

### Node revert (only with `--revert-nodes`)

```bash
kubectl taint nodes "$CP_NAME" node-role.kubernetes.io/control-plane=:NoSchedule
ssh <node> 'rm -f /etc/sysctl.d/99-kubeflow.conf && sysctl --system'
```

### Final report

```bash
kubectl get nodes
kubectl get ns
```

## After a `--revert-nodes` teardown

The control-plane is tainted `NoSchedule` again, so a re-deploy needs
`make prereqs` to untaint it before workloads will schedule there. `make all`
covers that as its first phase.

## What survives

The Kubernetes cluster itself, Calico/Tigera, the `kube-*` and `default`
namespaces, the CLI tools, and this repo. Everything else the repo installed is
removed, **including all PersistentVolume data** - pipelines, katib and notebook
contents are not recoverable afterwards.
