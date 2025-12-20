#!/usr/bin/env bash
# fix_mongo_auth.sh (fixed)
# Test MongoDB auth using in-cluster mongo client.
set -euo pipefail
IFS=$'\n\t'

NS="default"
SECRET_NAME="mongodb-secret"
DB_SERVICE="mongodb-service:27017"
TEST_IMAGE="mongo:4.4"
TEST_POD_NAME="mongo-client-test-$$"  # unique-ish

echo "[INFO] Namespace: $NS"
echo "[INFO] Reading secret: $SECRET_NAME"

USER_B64=$(kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.mongo-root-username}' 2>/dev/null || true)
PASS_B64=$(kubectl get secret "$SECRET_NAME" -n "$NS" -o jsonpath='{.data.mongo-root-password}' 2>/dev/null || true)

if [ -z "$USER_B64" ] || [ -z "$PASS_B64" ]; then
  echo "[ERROR] Could not read secret $SECRET_NAME (missing keys). Run: kubectl get secret $SECRET_NAME -n $NS -o yaml"
  exit 2
fi

USER=$(printf '%s' "$USER_B64" | base64 --decode)
PASS=$(printf '%s' "$PASS_B64" | base64 --decode)

echo "[INFO] Using user='$USER' (password hidden)"
URI="mongodb://${USER}:${PASS}@${DB_SERVICE}/admin"
echo "[INFO] Built URI: mongodb://<user>:<password>@${DB_SERVICE}/admin"

echo "[INFO] Running transient pod to test auth (will be auto-removed)..."

# Use --attach + --rm so kubectl waits and deletes pod after exit.
# The command uses bash -c so /dev/tcp and other bash features are available if needed.
kubectl run "$TEST_POD_NAME" \
  --image="$TEST_IMAGE" \
  --restart=Never \
  --attach --rm -i \
  -n "$NS" -- bash -c \
  "set -euo pipefail
   echo '[pod] Running mongo client ping...'
   mongo \"$URI\" --eval 'printjson(db.adminCommand({ping:1}))' --quiet
  "

RC=$? || true
if [ "$RC" -eq 0 ]; then
  echo "[SUCCESS] In-cluster authenticated ping worked."
else
  echo "[FAIL] In-cluster ping failed (exit code: $RC). See above output for details."
fi

exit "$RC"

