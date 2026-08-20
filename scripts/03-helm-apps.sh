#!/usr/bin/env bash
# Phase 3 - Kubeflow applications that DO have real, version-matched Helm charts
#   * KServe v0.18.0        (oci://ghcr.io/kserve/charts)
#   * Kubeflow Trainer 2.2.0 (oci://ghcr.io/kubeflow/charts)
#   * Spark Operator 2.5.0   (GitHub release chart tarball)
# Plus the KServe models web app, which has no chart and comes from kustomize.
#
# Each component honours its INSTALL_* flag in cluster.env:
#   helm | kustomize | off
# Components set to "kustomize" were already applied in Phase 2.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cluster
require_helm

[[ -d "${MANIFESTS_DIR}" ]] || die "manifests not found - run 'make core' first"

kubectl get namespace kubeflow >/dev/null 2>&1 \
  || die "kubeflow namespace missing - run 'make core' first"

# ---------------------------------------------------------------------------
step "KServe ${KSERVE_VERSION} (mode: ${INSTALL_KSERVE})"
# ---------------------------------------------------------------------------
if [[ "${INSTALL_KSERVE}" == "helm" ]]; then
  # Keep a local copy of the chart: we need its files/ directory to repair the
  # ClusterStorageContainer CRD (see below).
  KSERVE_CRD_CHART="${CACHE_DIR}/kserve-crd"
  if [[ ! -d "${KSERVE_CRD_CHART}" ]]; then
    log "fetching kserve-crd chart ${KSERVE_VERSION}"
    mkdir -p "${CACHE_DIR}"
    ( cd "${CACHE_DIR}" \
      && helm pull "oci://ghcr.io/kserve/charts/kserve-crd" --version "${KSERVE_VERSION}" >/dev/null 2>&1 \
      && tar -xzf "kserve-crd-${KSERVE_VERSION}.tgz" )
  fi

  if helm status kserve-crd -n kubeflow >/dev/null 2>&1; then
    # DO NOT run `helm upgrade` here. The chart guards its
    # ClusterStorageContainer CRD with a `lookup` that renders it only when it
    # is absent. On an upgrade the CRD already exists, the guard renders
    # nothing, and Helm then PRUNES the CRD as a removed resource - which
    # immediately breaks the kserve-resources release that depends on it.
    ok "kserve-crd already installed; skipping upgrade (chart prunes CRDs on upgrade)"
  else
    log "kserve-crd"
    helm install kserve-crd "oci://ghcr.io/kserve/charts/kserve-crd" \
      --version "${KSERVE_VERSION}" \
      --namespace kubeflow \
      --wait --timeout 5m
  fi

  # Reconcile the guarded CRD directly so the set is complete either way.
  if ! kubectl get crd clusterstoragecontainers.serving.kserve.io >/dev/null 2>&1; then
    warn "ClusterStorageContainer CRD missing - applying it from the chart"
    kubectl apply --server-side --force-conflicts \
      -f "${KSERVE_CRD_CHART}/files/serving.kserve.io_clusterstoragecontainers.yaml" >/dev/null
  fi

  wait_for_crd inferenceservices.serving.kserve.io
  wait_for_crd servingruntimes.serving.kserve.io
  wait_for_crd clusterstoragecontainers.serving.kserve.io

  log "kserve-resources (controller)"
  helm upgrade --install kserve \
    "oci://ghcr.io/kserve/charts/kserve-resources" \
    --version "${KSERVE_VERSION}" \
    --namespace kubeflow \
    --values "${REPO_ROOT}/values/kserve.yaml" \
    --wait --timeout 10m

  wait_for_pods kubeflow "control-plane=kserve-controller-manager" 420 \
    || warn "kserve controller slow to start; check 'kubectl -n kubeflow logs -l control-plane=kserve-controller-manager'"
  ok "KServe installed via Helm (RawDeployment mode)"
elif [[ "${INSTALL_KSERVE}" == "kustomize" ]]; then
  ok "KServe was installed via kustomize in Phase 2"
else
  warn "KServe skipped (INSTALL_KSERVE=off)"
fi

# The models web app has no Helm chart; it is kustomize-only. It renders the
# "Endpoints" section of the Central Dashboard.
if [[ "${INSTALL_KSERVE}" != "off" ]]; then
  log "kserve-models-web-app (kustomize - no chart exists)"
  retry 10 15 bash -c "kustomize build '${MANIFESTS_DIR}/applications/kserve/models-web-app/overlays/kubeflow' \
    | kubectl apply --server-side --force-conflicts -f - >/dev/null"
  ok "models web app applied"
fi

# ---------------------------------------------------------------------------
step "Kubeflow Trainer ${TRAINER_VERSION} (mode: ${INSTALL_TRAINER})"
# ---------------------------------------------------------------------------
if [[ "${INSTALL_TRAINER}" == "helm" ]]; then
  helm upgrade --install kubeflow-trainer \
    "oci://ghcr.io/kubeflow/charts/kubeflow-trainer" \
    --version "${TRAINER_VERSION}" \
    --namespace kubeflow \
    --values "${REPO_ROOT}/values/kubeflow-trainer.yaml" \
    --wait --timeout 10m
  ok "Trainer installed via Helm"
elif [[ "${INSTALL_TRAINER}" == "kustomize" ]]; then
  ok "Trainer was installed via kustomize in Phase 2"
else
  warn "Trainer skipped (INSTALL_TRAINER=off)"
fi

# ---------------------------------------------------------------------------
step "Spark Operator ${SPARK_OPERATOR_VERSION} (mode: ${INSTALL_SPARK})"
# ---------------------------------------------------------------------------
if [[ "${INSTALL_SPARK}" == "helm" ]]; then
  # Not published to a Helm repo or OCI registry; the release tarball is the
  # supported artifact.
  SPARK_CHART="https://github.com/kubeflow/spark-operator/releases/download/v${SPARK_OPERATOR_VERSION}/spark-operator-${SPARK_OPERATOR_VERSION}.tgz"
  helm upgrade --install spark-operator "${SPARK_CHART}" \
    --namespace kubeflow \
    --values "${REPO_ROOT}/values/spark-operator.yaml" \
    --wait --timeout 10m
  ok "Spark Operator installed via Helm"
elif [[ "${INSTALL_SPARK}" == "kustomize" ]]; then
  ok "Spark Operator was installed via kustomize in Phase 2"
else
  warn "Spark Operator skipped (INSTALL_SPARK=off)"
fi

# ---------------------------------------------------------------------------
step "Dashboard integration for Helm-installed components"
# ---------------------------------------------------------------------------
# Components installed by Helm do not register themselves in the Central
# Dashboard sidebar - that menu lives in the `centraldashboard-config` ConfigMap
# which Kubeflow's kustomize owns. Make sure the Endpoints (KServe) entry is
# present so Helm-installed KServe is still reachable from the UI.
DASH_CM="dashboard-config"   # named centraldashboard-config before 26.03
if kubectl -n kubeflow get configmap "${DASH_CM}" >/dev/null 2>&1; then
  if kubectl -n kubeflow get configmap "${DASH_CM}" -o jsonpath='{.data.links}' \
       | grep -q 'kserve-endpoints'; then
    ok "Central Dashboard lists the KServe Endpoints menu entry"
  else
    warn "Central Dashboard has no KServe entry; the models web app overlay normally adds it."
    warn "If Endpoints is missing in the UI, re-run: make apps"
  fi

  # Hub ships the Model Registry menu entry. With INSTALL_HUB=off the entry is
  # still rendered by the dashboard config but has no backend behind it.
  if [[ "${INSTALL_HUB}" == "off" ]] && \
     kubectl -n kubeflow get configmap "${DASH_CM}" -o jsonpath='{.data.links}' \
       | grep -q 'model-registry'; then
    warn "Dashboard shows a 'Model Registry' menu entry, but Hub is disabled (INSTALL_HUB=off)."
    warn "That link will 404. Set INSTALL_HUB=kustomize in cluster.env to deploy it (+2112Mi RAM)."
  fi
else
  warn "${DASH_CM} not found - Phase 2 may still be settling"
fi

# ---------------------------------------------------------------------------
step "Phase 3 summary"
# ---------------------------------------------------------------------------
helm list -A
echo
kubectl get pods -n kubeflow
echo
ok "Phase 3 complete. Next: make verify"
