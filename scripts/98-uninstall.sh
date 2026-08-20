#!/usr/bin/env bash
# Remove everything this repo installed. Leaves the Kubernetes cluster, its CNI
# (Calico) and this repo untouched.
#
#   bash scripts/98-uninstall.sh                  interactive confirmation
#   bash scripts/98-uninstall.sh --yes            no prompt
#   bash scripts/98-uninstall.sh --yes --revert-nodes
#                                                 also re-taint the control-plane
#                                                 and drop the inotify sysctl file
#
# Order matters: CRs before CRDs, PVCs before the provisioner, apps before Istio.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cluster

ASSUME_YES="no"
REVERT_NODES="no"
for arg in "$@"; do
  case "${arg}" in
    --yes|-y)       ASSUME_YES="yes" ;;
    --revert-nodes) REVERT_NODES="yes" ;;
    *) die "unknown argument: ${arg}" ;;
  esac
done

# API groups this repo introduced. Everything else - notably Calico's
# crd.projectcalico.org / operator.tigera.io and the cluster's own
# policy.networking.k8s.io - is left strictly alone.
OUR_CRD_GROUPS=(
  kubeflow.org trainer.kubeflow.org tensorboard.kubeflow.org
  serving.kserve.io
  networking.istio.io security.istio.io telemetry.istio.io extensions.istio.io install.istio.io
  cert-manager.io acme.cert-manager.io
  dex.coreos.com
  argoproj.io
  metacontroller.k8s.io
  sparkoperator.k8s.io
  jobset.x-k8s.io
)

echo
warn "This removes Kubeflow, KServe/Trainer/Spark, Istio, cert-manager and the"
warn "local-path StorageClass, plus ALL PersistentVolume data (pipelines, katib,"
warn "notebooks). The Kubernetes cluster, Calico and this repo are kept."
if [[ "${REVERT_NODES}" == "yes" ]]; then
  warn "Node changes will also be reverted (control-plane re-tainted, sysctl removed)."
fi
echo
if [[ "${ASSUME_YES}" != "yes" ]]; then
  read -r -p "Type 'yes' to continue: " CONFIRM
  [[ "${CONFIRM}" == "yes" ]] || { echo "aborted"; exit 1; }
fi

# ---------------------------------------------------------------------------
step "1/7 Removing Helm applications"
# ---------------------------------------------------------------------------
for rel in spark-operator kubeflow-trainer kserve kserve-crd; do
  if helm status "${rel}" -n kubeflow >/dev/null 2>&1; then
    log "uninstalling ${rel}"
    helm uninstall "${rel}" -n kubeflow --wait --timeout 5m >/dev/null 2>&1 \
      || warn "${rel} uninstall reported errors (continuing)"
  fi
done
ok "Helm applications removed"

# ---------------------------------------------------------------------------
step "2/7 Removing kustomize-managed Kubeflow core"
# ---------------------------------------------------------------------------
RENDERED="${CACHE_DIR}/kubeflow-core.yaml"
if [[ -f "${RENDERED}" ]]; then
  kubectl delete -f "${RENDERED}" --ignore-not-found --wait=false --timeout=60s >/dev/null 2>&1 || true
  ok "core manifest deletion requested"
else
  warn "no rendered manifest cached - falling back to namespace deletion"
fi

# ---------------------------------------------------------------------------
step "3/7 Deleting PVCs (before the provisioner, so volumes are reclaimed)"
# ---------------------------------------------------------------------------
kubectl delete pvc --all -n kubeflow --ignore-not-found --timeout=120s >/dev/null 2>&1 || true
# Give local-path's reclaim jobs a moment to clear the on-disk directories.
for _ in $(seq 1 12); do
  [[ -z "$(kubectl get pv --no-headers 2>/dev/null || true)" ]] && break
  sleep 5
done
REMAINING_PV="$( (kubectl get pv --no-headers 2>/dev/null || true) | wc -l )"
(( REMAINING_PV == 0 )) && ok "all PersistentVolumes reclaimed" \
  || warn "${REMAINING_PV} PV(s) still present; will force-remove below"

# ---------------------------------------------------------------------------
step "4/7 Deleting namespaces"
# ---------------------------------------------------------------------------
for ns in kubeflow "${KF_PROFILE_NAME}" auth oauth2-proxy; do
  kubectl delete namespace "${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
done
log "waiting for namespaces to terminate (up to 3 min)"
for _ in $(seq 1 36); do
  # `kubectl get` exits non-zero once every named namespace is gone, which under
  # `set -o pipefail` would abort the script - hence the guard.
  LEFT="$( (kubectl get ns kubeflow "${KF_PROFILE_NAME}" auth oauth2-proxy \
            --no-headers 2>/dev/null || true) | wc -l )"
  (( LEFT == 0 )) && break
  sleep 5
done
ok "application namespaces gone (or terminating)"

# ---------------------------------------------------------------------------
step "5/7 Removing Helm infrastructure"
# ---------------------------------------------------------------------------
for rel in istio-ingressgateway istio-cni istiod istio-base; do
  helm status "${rel}" -n istio-system >/dev/null 2>&1 \
    && { log "uninstalling ${rel}"; helm uninstall "${rel}" -n istio-system >/dev/null 2>&1 || true; }
done
helm status cert-manager -n cert-manager >/dev/null 2>&1 \
  && { log "uninstalling cert-manager"; helm uninstall cert-manager -n cert-manager >/dev/null 2>&1 || true; }
helm status local-path-provisioner -n local-path-storage >/dev/null 2>&1 \
  && { log "uninstalling local-path-provisioner"; helm uninstall local-path-provisioner -n local-path-storage >/dev/null 2>&1 || true; }

for ns in istio-system cert-manager local-path-storage; do
  kubectl delete namespace "${ns}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
done
kubectl delete pv --all --ignore-not-found --wait=false >/dev/null 2>&1 || true
ok "infrastructure releases removed"

# ---------------------------------------------------------------------------
step "6/7 Sweeping leftover CRDs"
# ---------------------------------------------------------------------------
# Only groups this repo introduced. Calico's CRDs are never touched.
SWEPT=0
for group in "${OUR_CRD_GROUPS[@]}"; do
  MATCHES="$( (kubectl get crd --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null || true) \
             | grep -E "\.${group}$" || true)"
  [[ -z "${MATCHES}" ]] && continue
  while read -r crd; do
    [[ -z "${crd}" ]] && continue
    kubectl delete crd "${crd}" --ignore-not-found --wait=false --timeout=30s >/dev/null 2>&1 || true
    SWEPT=$(( SWEPT + 1 ))
  done <<< "${MATCHES}"
done
ok "${SWEPT} CRD(s) deleted"

log "verifying Calico CRDs are intact"
CALICO_LEFT="$( (kubectl get crd --no-headers 2>/dev/null || true) \
  | grep -cE 'crd\.projectcalico\.org|operator\.tigera\.io' || true)"
(( CALICO_LEFT >= 30 )) && ok "Calico CRDs intact (${CALICO_LEFT})" \
  || warn "expected ~31 Calico CRDs, found ${CALICO_LEFT} - check the CNI"

# ---------------------------------------------------------------------------
step "7/7 Cleaning volume data on nodes"
# ---------------------------------------------------------------------------
for host in "${CP_IP}" "${WORKER_IP}"; do
  if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" true 2>/dev/null; then
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
      'rm -rf /opt/local-path-provisioner/* 2>/dev/null; true' >/dev/null 2>&1 || true
    ok "${host}: volume directory cleared"
  else
    warn "${host}: unreachable, skipped volume cleanup"
  fi
done

# ---------------------------------------------------------------------------
if [[ "${REVERT_NODES}" == "yes" ]]; then
  step "Reverting node changes made by Phase 0"
  # ---------------------------------------------------------------------------
  if kubectl get node "${CP_NAME}" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null \
       | grep -q 'node-role.kubernetes.io/control-plane'; then
    ok "${CP_NAME} already tainted"
  else
    kubectl taint nodes "${CP_NAME}" \
      node-role.kubernetes.io/control-plane=:NoSchedule >/dev/null 2>&1 \
      && ok "${CP_NAME} NoSchedule taint restored" \
      || warn "could not re-taint ${CP_NAME}"
  fi

  for host in "${CP_IP}" "${WORKER_IP}"; do
    if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" true 2>/dev/null; then
      ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        'rm -f /etc/sysctl.d/99-kubeflow.conf && sysctl --system >/dev/null 2>&1; true' \
        >/dev/null 2>&1 || true
      ok "${host}: inotify sysctl file removed"
    else
      warn "${host}: unreachable, sysctl file not removed"
    fi
  done
fi

# ---------------------------------------------------------------------------
step "Done"
# ---------------------------------------------------------------------------
echo
kubectl get nodes
echo
kubectl get ns
echo
ok "Teardown complete. Re-deploy any time with: make all"
