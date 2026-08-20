#!/usr/bin/env bash
# Phase 0 - Prerequisites
#   * install kubectl / helm / kustomize on this box
#   * pull the admin kubeconfig off the control-plane node
#   * untaint the control-plane so workloads can schedule there
#   * raise inotify limits on both nodes (Istio CNI + Notebooks need them)
# Idempotent: safe to re-run.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  GOARCH="amd64" ;;
  aarch64) GOARCH="arm64" ;;
  *) die "unsupported architecture: ${ARCH}" ;;
esac

# ---------------------------------------------------------------------------
step "Installing CLI tools (kubectl ${KUBECTL_VERSION}, helm ${HELM_VERSION}, kustomize ${KUSTOMIZE_VERSION})"
# ---------------------------------------------------------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

install_kubectl() {
  if [[ "$(kubectl version --client -o json 2>/dev/null | grep -o '"gitVersion": *"[^"]*"' | head -1)" == *"${KUBECTL_VERSION}"* ]]; then
    ok "kubectl ${KUBECTL_VERSION} already installed"; return
  fi
  log "downloading kubectl ${KUBECTL_VERSION}"
  curl -fsSL -o "${TMP}/kubectl" \
    "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${GOARCH}/kubectl"
  install -m 0755 "${TMP}/kubectl" /usr/local/bin/kubectl
  ok "kubectl installed"
}

install_helm() {
  if [[ "$(helm version --short 2>/dev/null)" == "${HELM_VERSION}"* ]]; then
    ok "helm ${HELM_VERSION} already installed"; return
  fi
  log "downloading helm ${HELM_VERSION}"
  curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${GOARCH}.tar.gz" \
    | tar -xz -C "${TMP}"
  install -m 0755 "${TMP}/linux-${GOARCH}/helm" /usr/local/bin/helm
  ok "helm installed"
}

install_kustomize() {
  if [[ "$(kustomize version 2>/dev/null)" == *"${KUSTOMIZE_VERSION}"* ]]; then
    ok "kustomize ${KUSTOMIZE_VERSION} already installed"; return
  fi
  log "downloading kustomize ${KUSTOMIZE_VERSION}"
  curl -fsSL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${GOARCH}.tar.gz" \
    | tar -xz -C "${TMP}"
  install -m 0755 "${TMP}/kustomize" /usr/local/bin/kustomize
  ok "kustomize installed"
}

install_kubectl
install_helm
install_kustomize

for tool in git make curl tar python3; do
  command -v "${tool}" >/dev/null 2>&1 \
    || die "${tool} is required but not installed (apt-get install -y ${tool})"
done
ok "git, make, curl, tar, python3 present"

# ---------------------------------------------------------------------------
step "Fetching kubeconfig from ${CP_NAME} (${CP_IP})"
# ---------------------------------------------------------------------------
ssh_cp true 2>/dev/null || die "cannot SSH to ${SSH_USER}@${CP_IP}. Fix key-based SSH first."

mkdir -p "$(dirname "${KUBECONFIG}")"
if [[ -f "${KUBECONFIG}" ]]; then
  cp -a "${KUBECONFIG}" "${KUBECONFIG}.bak.$(date +%s)"
  log "existing kubeconfig backed up"
fi

ssh_cp 'cat /etc/kubernetes/admin.conf' > "${TMP}/admin.conf"
[[ -s "${TMP}/admin.conf" ]] || die "admin.conf came back empty"

# Point the client at the node IP rather than whatever internal name/VIP the
# cluster was bootstrapped with.
sed -i -E "s#server: https://[^[:space:]]+#server: https://${CP_IP}:6443#" "${TMP}/admin.conf"
install -m 0600 "${TMP}/admin.conf" "${KUBECONFIG}"
ok "kubeconfig written to ${KUBECONFIG}"

log "verifying API server certificate covers ${CP_IP}"
if ! kubectl version -o json >/dev/null 2>&1; then
  warn "connection failed with the rewritten server address."
  warn "The API cert SANs probably do not include ${CP_IP}. SANs present:"
  ssh_cp "openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text \
    | grep -A1 'Subject Alternative Name'" 2>&1 | sed 's/^/     /' >&2 || true
  die "kubeconfig unusable from this host; run the scripts on ${CP_NAME} instead."
fi
ok "cluster reachable: $(kubectl get nodes --no-headers | wc -l) node(s)"

# ---------------------------------------------------------------------------
step "Removing control-plane NoSchedule taint"
# ---------------------------------------------------------------------------
# Kubeflow 26.03.1 requests ~9Gi RAM after trimming; a single 7.2Gi worker
# cannot hold it. Untainting brings the cluster to ~14.4Gi schedulable.
if kubectl get node "${CP_NAME}" -o jsonpath='{.spec.taints[*].key}' 2>/dev/null \
     | grep -q 'node-role.kubernetes.io/control-plane'; then
  kubectl taint nodes "${CP_NAME}" node-role.kubernetes.io/control-plane-
  ok "taint removed from ${CP_NAME}"
else
  ok "${CP_NAME} already schedulable"
fi

# ---------------------------------------------------------------------------
step "Raising inotify / pid limits on both nodes"
# ---------------------------------------------------------------------------
SYSCTL_CONF='fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 655360'

apply_sysctl() {
  local label="$1"; shift
  log "applying sysctl on ${label}"
  "$@" "printf '%s\n' '${SYSCTL_CONF}' > /etc/sysctl.d/99-kubeflow.conf && sysctl -p /etc/sysctl.d/99-kubeflow.conf" \
    >/dev/null 2>&1 && ok "${label} sysctl applied" \
    || warn "could not apply sysctl on ${label}; do it manually if Istio CNI misbehaves"
}

apply_sysctl "${CP_NAME}" ssh_cp
if ssh_worker true 2>/dev/null; then
  apply_sysctl "${WORKER_NAME}" ssh_worker
else
  warn "direct SSH to ${WORKER_IP} unavailable - hopping via ${CP_NAME}"
  if ssh_cp "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${WORKER_IP} true" 2>/dev/null; then
    apply_sysctl "${WORKER_NAME}" run_on_worker
  else
    warn "cannot reach ${WORKER_NAME} from anywhere. Run this on it by hand:"
    warn "  printf 'fs.inotify.max_user_instances = 8192\\nfs.inotify.max_user_watches = 655360\\n' > /etc/sysctl.d/99-kubeflow.conf && sysctl --system"
  fi
fi

# ---------------------------------------------------------------------------
step "Phase 0 summary"
# ---------------------------------------------------------------------------
kubectl get nodes -o wide
echo
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints
echo
ok "Phase 0 complete. Next: make infra"
