#!/usr/bin/env bash
# Phase 4 - Verification
# Read-only. Exits non-zero if anything essential is broken.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_cluster

FAILURES=0
fail() { echo "${C_RED}  FAIL${C_RESET} $*"; FAILURES=$(( FAILURES + 1 )); }
pass() { echo "${C_GREEN}  pass${C_RESET} $*"; }

# ---------------------------------------------------------------------------
step "Nodes"
# ---------------------------------------------------------------------------
kubectl get nodes -o wide
NOT_READY="$(kubectl get nodes --no-headers | awk '$2 != "Ready" {print $1}')"
[[ -z "${NOT_READY}" ]] && pass "all nodes Ready" || fail "nodes not Ready: ${NOT_READY}"

# ---------------------------------------------------------------------------
step "Helm releases"
# ---------------------------------------------------------------------------
helm list -A
BAD_RELEASES="$(helm list -A -o json | grep -o '"status":"[^"]*"' | grep -v '"status":"deployed"' || true)"
[[ -z "${BAD_RELEASES}" ]] && pass "all Helm releases deployed" || fail "releases not deployed: ${BAD_RELEASES}"

# ---------------------------------------------------------------------------
step "Pod health"
# ---------------------------------------------------------------------------
for ns in istio-system cert-manager local-path-storage auth oauth2-proxy kubeflow; do
  kubectl get namespace "${ns}" >/dev/null 2>&1 || { warn "namespace ${ns} absent, skipping"; continue; }
  BROKEN="$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
    | awk '$3 != "Running" && $3 != "Completed" && $3 != "Succeeded" { print $1" ("$3")" }')"
  UNREADY="$(kubectl get pods -n "${ns}" --no-headers 2>/dev/null \
    | awk '$3 == "Running" { split($2, a, "/"); if (a[1] != a[2]) print $1" ("$2")" }')"
  if [[ -z "${BROKEN}${UNREADY}" ]]; then
    pass "${ns}: all pods healthy ($(kubectl get pods -n "${ns}" --no-headers | wc -l) pods)"
  else
    fail "${ns}: ${BROKEN} ${UNREADY}"
  fi
done

# ---------------------------------------------------------------------------
step "Storage"
# ---------------------------------------------------------------------------
kubectl get pvc -A 2>/dev/null || true
UNBOUND="$(kubectl get pvc -A --no-headers 2>/dev/null | awk '$3 != "Bound" { print $2" ("$3")" }')"
if [[ -z "${UNBOUND}" ]]; then
  pass "all PVCs Bound"
else
  # WaitForFirstConsumer PVCs stay Pending until a pod mounts them - only a
  # problem if the owning pod is also stuck.
  fail "PVCs not Bound: ${UNBOUND}"
fi

# ---------------------------------------------------------------------------
step "Istio wiring"
# ---------------------------------------------------------------------------
if kubectl -n istio-system get gateway istio-ingressgateway >/dev/null 2>&1; then
  pass "Kubeflow Gateway present"
else
  fail "Gateway istio-ingressgateway missing - VirtualServices will not route"
fi

if kubectl -n istio-system get cm istio -o jsonpath='{.data.mesh}' 2>/dev/null \
     | grep -q 'name: oauth2-proxy'; then
  pass "oauth2-proxy ext-authz provider present in mesh config"
else
  fail "mesh config missing the oauth2-proxy extensionProvider - logins will fail"
fi

# ---------------------------------------------------------------------------
step "HTTP reachability"
# ---------------------------------------------------------------------------
URL="http://${CP_IP}:${KF_HTTP_NODEPORT}"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "${URL}" || echo 000)"
case "${CODE}" in
  # 403 is the NORMAL unauthenticated response here: Istio's CUSTOM
  # AuthorizationPolicy calls oauth2-proxy, which serves its "Sign In" page
  # with a 403 rather than a redirect. Envoy logs it as ext_authz_denied.
  200|302|303|403) pass "${URL} responded HTTP ${CODE} (auth challenge served)" ;;
  000)             fail "${URL} unreachable - check the NodePort service and firewall" ;;
  *)               warn "${URL} responded HTTP ${CODE}; may still be starting up" ;;
esac

# Follow the flow through to the Dex login page - proves oauth2-proxy, Istio
# ext-authz and dex are all wired together, not just that something answered.
LOGIN_URL="$(curl -s -L -o /dev/null --max-time 25 -w '%{url_effective}' \
  "${URL}/oauth2/start" 2>/dev/null || true)"
if [[ "${LOGIN_URL}" == *"/dex/auth"* ]]; then
  pass "auth flow reaches the Dex login page"
else
  fail "auth flow did not reach dex (landed on: ${LOGIN_URL:-nothing})"
fi

# ---------------------------------------------------------------------------
step "End-to-end login"
# ---------------------------------------------------------------------------
# Actually log in and call an authenticated API. This is what catches the
# ingressgateway ServiceAccount-name mismatch, which leaves every UI returning
# "RBAC: access denied" while every pod still looks perfectly healthy.
JAR="$(mktemp)"; trap 'rm -f "${JAR}"' EXIT
DEX_LOGIN="$(curl -s -c "${JAR}" -b "${JAR}" -L -o /dev/null -w '%{url_effective}' \
  --max-time 25 "${URL}/oauth2/start" 2>/dev/null || true)"
CALLBACK="$(curl -s -c "${JAR}" -b "${JAR}" -o /dev/null -D- --max-time 30 \
  --data-urlencode "login=${KF_USER_EMAIL}" \
  --data-urlencode "password=${KF_USER_PASSWORD}" "${DEX_LOGIN}" 2>/dev/null \
  | grep -i '^location' | tr -d '\r' | sed 's/location: //I' || true)"

if [[ -z "${CALLBACK}" ]]; then
  fail "dex rejected the credentials for ${KF_USER_EMAIL}"
else
  curl -s -c "${JAR}" -b "${JAR}" -o /dev/null --max-time 30 "${URL}${CALLBACK}" 2>/dev/null || true
  DASH_CODE="$(curl -s -b "${JAR}" -o /dev/null -w '%{http_code}' --max-time 25 "${URL}/" || echo 000)"
  if [[ "${DASH_CODE}" == "200" ]]; then
    pass "logged in as ${KF_USER_EMAIL}; Central Dashboard returned 200"
  else
    fail "post-login dashboard returned HTTP ${DASH_CODE} (403 => check the ingressgateway ServiceAccount name)"
  fi

  ENVINFO="$(curl -s -b "${JAR}" --max-time 25 "${URL}/api/workgroup/env-info" 2>/dev/null || true)"
  if [[ "${ENVINFO}" == *"${KF_PROFILE_NAME}"* ]]; then
    pass "KFAM API returns the user's namespace (${KF_PROFILE_NAME})"
  else
    fail "KFAM API did not return the expected namespace"
  fi
fi

# ---------------------------------------------------------------------------
step "User profile"
# ---------------------------------------------------------------------------
# Fully qualified: Calico also registers a "Profile" kind
# (profiles.crd.projectcalico.org), and the short name resolves to that one.
if kubectl get profiles.kubeflow.org "${KF_PROFILE_NAME}" >/dev/null 2>&1; then
  pass "profile ${KF_PROFILE_NAME} exists"
  kubectl get namespace "${KF_PROFILE_NAME}" >/dev/null 2>&1 \
    && pass "profile namespace created" \
    || fail "profile namespace missing - profile-controller may be unhealthy"
else
  fail "profile ${KF_PROFILE_NAME} missing"
fi

# ---------------------------------------------------------------------------
step "Result"
# ---------------------------------------------------------------------------
echo
if (( FAILURES == 0 )); then
  echo "${C_GREEN}================================================${C_RESET}"
  echo "${C_GREEN} Kubeflow is up.${C_RESET}"
  echo "${C_GREEN}================================================${C_RESET}"
  echo
  echo "  URL       ${URL}"
  echo "  Username  ${KF_USER_EMAIL}"
  echo "  Password  ${KF_USER_PASSWORD}"
  echo
  echo "  Namespace ${KF_PROFILE_NAME}"
  exit 0
else
  echo "${C_RED}${FAILURES} check(s) failed.${C_RESET} See docs/troubleshooting.md"
  echo "Hint: 'make status' shows every unhealthy pod."
  exit 1
fi
