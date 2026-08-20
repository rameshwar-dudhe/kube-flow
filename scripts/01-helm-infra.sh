#!/usr/bin/env bash
# Phase 1 - Infrastructure layer, all via Helm
#   * local-path-provisioner  -> default StorageClass (cluster had none)
#   * cert-manager v1.20.2    -> webhook certs for Kubeflow components
#   * Istio 1.30.1            -> base / istiod / cni / ingressgateway
# Idempotent: every install is `helm upgrade --install`.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cluster
require_helm

ISTIO_CHARTS="https://istio-release.storage.googleapis.com/charts"

# ---------------------------------------------------------------------------
step "local-path-provisioner ${LOCAL_PATH_VERSION} (default StorageClass)"
# ---------------------------------------------------------------------------
# Rancher does not publish this chart to a Helm repo, so pull the chart source
# at the pinned tag and install from the local path. Still a real Helm release.
LPP_SRC="${CACHE_DIR}/local-path-provisioner"
mkdir -p "${CACHE_DIR}"
if [[ ! -d "${LPP_SRC}/.git" ]]; then
  log "cloning local-path-provisioner ${LOCAL_PATH_VERSION}"
  git clone --depth 1 --branch "${LOCAL_PATH_VERSION}" \
    https://github.com/rancher/local-path-provisioner.git "${LPP_SRC}" >/dev/null 2>&1
else
  log "reusing cached chart at ${LPP_SRC}"
fi

helm upgrade --install local-path-provisioner \
  "${LPP_SRC}/deploy/chart/local-path-provisioner" \
  --namespace local-path-storage --create-namespace \
  --values "${REPO_ROOT}/values/local-path-provisioner.yaml" \
  --wait --timeout 5m

wait_for_pods local-path-storage "app.kubernetes.io/name=local-path-provisioner" 300

DEFAULT_SC="$(kubectl get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}')"
[[ -n "${DEFAULT_SC}" ]] || die "no default StorageClass after install - Kubeflow PVCs will hang"
ok "default StorageClass: ${DEFAULT_SC}"

# ---------------------------------------------------------------------------
step "cert-manager ${CERT_MANAGER_VERSION}"
# ---------------------------------------------------------------------------
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo update jetstack >/dev/null

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --values "${REPO_ROOT}/values/cert-manager.yaml" \
  --wait --timeout 8m

wait_for_pods cert-manager "app.kubernetes.io/instance=cert-manager" 420
ok "cert-manager ready"

# ---------------------------------------------------------------------------
step "Istio ${ISTIO_VERSION}"
# ---------------------------------------------------------------------------
kubectl get namespace istio-system >/dev/null 2>&1 || kubectl create namespace istio-system

log "istio-base (CRDs)"
helm upgrade --install istio-base "${ISTIO_CHARTS}/base-${ISTIO_VERSION}.tgz" \
  --namespace istio-system \
  --set defaultRevision=default \
  --wait --timeout 5m

wait_for_crd virtualservices.networking.istio.io
wait_for_crd gateways.networking.istio.io
wait_for_crd authorizationpolicies.security.istio.io

log "istiod (control plane)"
helm upgrade --install istiod "${ISTIO_CHARTS}/istiod-${ISTIO_VERSION}.tgz" \
  --namespace istio-system \
  --values "${REPO_ROOT}/values/istiod.yaml" \
  --wait --timeout 8m

wait_for_pods istio-system "app=istiod" 420

log "istio-cni (node agent)"
helm upgrade --install istio-cni "${ISTIO_CHARTS}/cni-${ISTIO_VERSION}.tgz" \
  --namespace istio-system \
  --values "${REPO_ROOT}/values/istio-cni.yaml" \
  --wait --timeout 5m

log "istio-ingressgateway (NodePort ${KF_HTTP_NODEPORT})"
# Release name matters: it produces the istio=ingressgateway label that
# Kubeflow's Gateway resource selects on.
helm upgrade --install istio-ingressgateway "${ISTIO_CHARTS}/gateway-${ISTIO_VERSION}.tgz" \
  --namespace istio-system \
  --values "${REPO_ROOT}/values/istio-ingressgateway.yaml" \
  --wait --timeout 5m

wait_for_pods istio-system "istio=ingressgateway" 300

# ---------------------------------------------------------------------------
step "Phase 1 summary"
# ---------------------------------------------------------------------------
helm list -A
echo
kubectl get sc
echo
kubectl -n istio-system get svc istio-ingressgateway
echo
ok "Phase 1 complete. Next: make core"
