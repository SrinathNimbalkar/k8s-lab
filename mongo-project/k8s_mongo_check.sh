#!/usr/bin/env bash
# k8s_mongo_check.sh
# Run a series of checks for mongo-express <-> mongodb in-cluster connectivity.
# Usage:
#   ./k8s_mongo_check.sh                # run checks only
#   ./k8s_mongo_check.sh --restart      # restart mongo-express rollout after fixing env (optional)
#   ./k8s_mongo_check.sh --apply-uri    # set ME_CONFIG_MONGODB_URL in deployment from secret (quick fix)
#
# Notes:
# - Requires kubectl in PATH and context set to the cluster where your pods run.
# - Uses jsonpath to safely read secret values.
# - If the mongo-express container lacks /bin/bash, the script will create a short-lived debug pod to run bash-based TCP tests.

set -uo pipefail
IFS=$'\n\t'

DEPLOYMENT="mongo-express"
APP_LABEL="app=mongo-express"
DB_LABEL="app=mongodb"
KUBE_NAMESPACE="default"

DO_ROLL_RESTART=false
DO_APPLY_URI=false

for arg in "$@"; do
  case "$arg" in
    --restart) DO_ROLL_RESTART=true ;;
    --apply-uri) DO_APPLY_URI=true ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--apply-uri] [--restart]
  --apply-uri   create/update a secret with the full mongo URI from mongodb-secret and patch deployment to use it
  --restart     restart mongo-express rollout (useful after applying env changes)
EOF
      exit 0
      ;;
    *) ;;
  esac
done

log() { printf '\033[1;36m[INFO]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

# safe command wrappers
kub() { kubectl "$@"; }

# 0) quick pre-checks
if ! command -v kubectl >/dev/null 2>&1; then
  err "kubectl not found in PATH"
  exit 2
fi

log "Using namespace: $KUBE_NAMESPACE"
log "Checking pods for mongo-express and mongodb..."

# 1) List mongo-express pods
kub get pods -l "$APP_LABEL" -n "$KUBE_NAMESPACE" -o wide || true
echo

# identify NEW and OLD pod (NEW = the one with youngest startTime if possible)
PODS_JSON=$(kub get pod -l "$APP_LABEL" -n "$KUBE_NAMESPACE" -o json 2>/dev/null || true)
if [ -z "$PODS_JSON" ]; then
  err "No pods found with label $APP_LABEL in namespace $KUBE_NAMESPACE"
  exit 1
fi

# choose pods in stable order: items[0] is fine for most clusters; also print both
POD_LIST=( $(kub get pod -l "$APP_LABEL" -n "$KUBE_NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') )
NEW_POD="${POD_LIST[0]:-}"
OLD_POD="${POD_LIST[1]:-}"

log "NEW POD: ${NEW_POD:-<none>}"
[ -n "$OLD_POD" ] && log "OLD POD: $OLD_POD"

# 2) Show logs for NEW pod only (to avoid mixing)
if [ -n "$NEW_POD" ]; then
  log "----- logs for NEW POD ($NEW_POD) -----"
  kub logs "$NEW_POD" -n "$KUBE_NAMESPACE" --tail=200 || true
else
  err "No NEW POD to show logs for"
fi
echo

# also show old pod logs if present (for comparison)
if [ -n "$OLD_POD" ]; then
  log "----- logs for OLD POD ($OLD_POD) -----"
  kub logs "$OLD_POD" -n "$KUBE_NAMESPACE" --tail=200 || true
  echo
fi

# 3) Show environment variables inside NEW pod related to mongo
if [ -n "$NEW_POD" ]; then
  log "----- env in NEW POD -----"
  kub exec -n "$KUBE_NAMESPACE" "$NEW_POD" -- /bin/sh -c 'env | grep -i "ME_CONFIG\|MONGO\|MONGODB" || true'
  echo
fi

# 4) DNS resolution from NEW POD
if [ -n "$NEW_POD" ]; then
  log "----- DNS resolution from NEW POD -----"
  kub exec -n "$KUBE_NAMESPACE" "$NEW_POD" -- /bin/sh -c 'cat /etc/resolv.conf; nslookup mongodb-service || true; getent hosts mongodb-service || true' || true
  echo
fi

# 5) TCP test: prefer /bin/bash inside container; if not present, run a temporary debug pod
tcp_test_from_pod() {
  local pod="$1"
  # try bash
  if kub exec -n "$KUBE_NAMESPACE" "$pod" -- /bin/bash -c 'echo ok' >/dev/null 2>&1; then
    kub exec -n "$KUBE_NAMESPACE" "$pod" -- /bin/bash -c 'if (echo > /dev/tcp/mongodb-service/27017) 2>/dev/null; then echo "TCP OK to mongodb-service:27017"; else echo "TCP FAILED to mongodb-service:27017"; fi'
  else
    log "Pod $pod has no /bin/bash; launching ephemeral debug pod for TCP test"
    kub run --rm -n "$KUBE_NAMESPACE" --restart=Never debug-tcp --image=infoblox/dnstools -- nslookup mongodb-service || true
    # note: infoblox/dnstools contains nslookup; do tcp test with busybox-ish image if available
    kub run --rm -n "$KUBE_NAMESPACE" --restart=Never tcp-test --image=busybox -- /bin/sh -c 'if (echo > /dev/tcp/mongodb-service/27017) 2>/dev/null; then echo "TCP OK"; else echo "TCP FAILED"; fi' || true
  fi
}

if [ -n "$NEW_POD" ]; then
  log "----- TCP test to mongodb-service:27017 from NEW POD (using bash if available) -----"
  tcp_test_from_pod "$NEW_POD"
  echo
fi

# 6) show mongodb pod and tail last logs
DB_POD=$(kub get pod -l "$DB_LABEL" -n "$KUBE_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -n "$DB_POD" ]; then
  log "MongoDB pod: $DB_POD"
  kub logs "$DB_POD" -n "$KUBE_NAMESPACE" --tail=50 || true
  echo
else
  err "No MongoDB pod found with label $DB_LABEL"
fi

# 7) in-cluster mongo client test (non-interactive)
log "----- test with in-cluster mongo client (ping) -----"
# fetch username/password safely using jsonpath (avoid template quoting issues)
USER="$(kub get secret mongodb-secret -n "$KUBE_NAMESPACE" -o jsonpath='{.data.mongo-root-username}' 2>/dev/null || true)"
PASS="$(kub get secret mongodb-secret -n "$KUBE_NAMESPACE" -o jsonpath='{.data.mongo-root-password}' 2>/dev/null || true)"

if [ -z "$USER" ] || [ -z "$PASS" ]; then
  err "Could not read mongodb-secret (mongo-root-username / mongo-root-password). Ensure the secret exists in namespace $KUBE_NAMESPACE."
else
  USER=$(echo "$USER" | base64 --decode)
  PASS=$(echo "$PASS" | base64 --decode)
  # run the mongo client non-interactively inside a short-lived pod (will print result)
  kub run --rm -n "$KUBE_NAMESPACE" --restart=Never mongo-client --image=mongo:4.4 -- bash -c "mongo \"mongodb://${USER}:${PASS}@mongodb-service:27017/admin\" --eval 'db.adminCommand({ping:1})' || echo 'mongo client test failed'"
fi
echo

# Optional quick fix: create secret with full URI and patch deployment to use it
if [ "${DO_APPLY_URI}" = true ]; then
  log "Creating/updating secret 'mongo-uri-secret' with ME_CONFIG_MONGODB_URL from mongodb-secret..."
  if [ -z "$USER" ] || [ -z "$PASS" ]; then
    err "Cannot build URI: username/password missing"
  else
    URI="mongodb://${USER}:${PASS}@mongodb-service:27017/admin"
    kub create secret generic mongo-uri-secret -n "$KUBE_NAMESPACE" --from-literal=ME_CONFIG_MONGODB_URL="$URI" --dry-run=client -o yaml | kub apply -f -
    log "Patching deployment to add ME_CONFIG_MONGODB_URL from secret (valueFrom.secretKeyRef)..."
    # attempt to add the env var; if env exists, replace it
    # we will generate a JSON patch that either adds or replaces env array entry
    # safer approach: replace entire containers[0].env with minimal env set (be careful in prod)
    kub patch deployment "$DEPLOYMENT" -n "$KUBE_NAMESPACE" --type='json' -p="$(
      cat <<'PATCH'
[
  {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"ME_CONFIG_MONGODB_URL","valueFrom":{"secretKeyRef":{"name":"mongo-uri-secret","key":"ME_CONFIG_MONGODB_URL"}}}}
]
PATCH
    )" || log "Patch may have failed (maybe env already exists) - you can patch manually if needed."
    echo
  fi
fi

# optional rollout restart
if [ "${DO_ROLL_RESTART}" = true ]; then
  log "Restarting rollout for deployment $DEPLOYMENT ..."
  kub rollout restart deployment/"$DEPLOYMENT" -n "$KUBE_NAMESPACE" || err "rollout restart failed"
  kub rollout status deployment/"$DEPLOYMENT" -n "$KUBE_NAMESPACE" --watch || true
  echo
fi

log "All checks completed. If mongo-express still shows 'Waiting for mongo' in logs, paste the NEW pod logs and the outputs above and I'll tell exact next step."

