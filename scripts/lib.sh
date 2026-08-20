#!/usr/bin/env bash
# Shared helpers. Sourced by every phase script.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../cluster.env
source "${REPO_ROOT}/cluster.env"

export KUBECONFIG="${KUBECONFIG:-/root/.kube/config}"
export PATH="/usr/local/bin:${PATH}"

# --- output ---------------------------------------------------------------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BLUE=$'\033[1;34m'; C_GREEN=$'\033[1;32m'
  C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi

log()   { echo "${C_BLUE}==>${C_RESET} $*"; }
ok()    { echo "${C_GREEN} ok${C_RESET} $*"; }
warn()  { echo "${C_YELLOW}  ! ${C_RESET}$*" >&2; }
die()   { echo "${C_RED}FAIL${C_RESET} $*" >&2; exit 1; }
step()  { echo; echo "${C_DIM}--------------------------------------------------------------${C_RESET}"; log "$*"; }

trap 'die "line $LINENO failed: ${BASH_COMMAND}"' ERR

# --- ssh ------------------------------------------------------------------
SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10)

ssh_cp()     { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${CP_IP}" "$@"; }
ssh_worker() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${WORKER_IP}" "$@"; }

# Run a command on the worker. Direct SSH if reachable, otherwise hop via the
# control-plane node (the worker may not trust this box's key).
run_on_worker() {
  if ssh_worker true 2>/dev/null; then
    ssh_worker "$@"
  else
    ssh_cp "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${WORKER_IP} '$*'"
  fi
}

# --- retry ----------------------------------------------------------------
# Upstream Kubeflow documents that `kubectl apply` legitimately fails on the
# first attempts (a CR cannot be created until its CRD is established).
retry() {
  local tries="$1" delay="$2"; shift 2
  local n=1
  until "$@"; do
    if (( n >= tries )); then
      return 1
    fi
    warn "attempt ${n}/${tries} failed, retrying in ${delay}s: $*"
    sleep "${delay}"
    (( n++ ))
  done
  return 0
}

# --- kubernetes waits -----------------------------------------------------
wait_for_crd() {
  local crd="$1" timeout="${2:-180}"
  log "waiting for CRD ${crd}"
  kubectl wait --for=condition=Established "crd/${crd}" --timeout="${timeout}s" >/dev/null
}

# Wait until a namespace has at least one pod matching the selector AND all of
# them are Ready. `kubectl wait` alone returns success against zero pods.
wait_for_pods() {
  local ns="$1" selector="$2" timeout="${3:-300}"
  local deadline=$(( SECONDS + timeout ))
  log "waiting for pods in ${ns} (${selector})"
  while (( SECONDS < deadline )); do
    local total
    total="$(kubectl get pods -n "${ns}" -l "${selector}" --no-headers 2>/dev/null | wc -l)"
    if (( total > 0 )); then
      if kubectl wait --for=condition=Ready pod -n "${ns}" -l "${selector}" \
           --timeout=10s >/dev/null 2>&1; then
        ok "${ns} (${selector}) ready"
        return 0
      fi
    fi
    sleep 5
  done
  warn "timeout waiting for ${ns} (${selector}); current state:"
  kubectl get pods -n "${ns}" -l "${selector}" 2>&1 | sed 's/^/     /' >&2 || true
  return 1
}

# Wait for every pod in a namespace to be Ready or Completed.
wait_namespace_ready() {
  local ns="$1" timeout="${2:-600}"
  local deadline=$(( SECONDS + timeout ))
  log "waiting for all pods in namespace ${ns}"
  while (( SECONDS < deadline )); do
    local notready
    notready="$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
      | awk '$3 != "Running" && $3 != "Completed" && $3 != "Succeeded" { print }' | wc -l)"
    local unready_containers
    unready_containers="$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
      | awk '$3 == "Running" { split($2, a, "/"); if (a[1] != a[2]) print }' | wc -l)"
    if (( notready == 0 && unready_containers == 0 )); then
      ok "namespace ${ns} fully ready"
      return 0
    fi
    sleep 10
  done
  warn "timeout waiting for namespace ${ns}; not-ready pods:"
  kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" || ($3 == "Running" && $2 !~ /^([0-9]+)\/\1$/)' \
    | sed 's/^/     /' >&2 || true
  return 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"; }

# Guard: every phase after 00 needs a working cluster connection.
require_cluster() {
  need_cmd kubectl
  kubectl version -o json >/dev/null 2>&1 \
    || die "cannot reach the cluster. Run 'make prereqs' first."
}

require_helm() {
  need_cmd helm
}
