#!/usr/bin/env bash
# forward-all.sh — simple one-terminal port-forward launcher for minikube observability
# Usage: ./forward-all.sh
# Assumes KUBECONFIG is set to /Users/shrinath.nimbalkar/.kube/config_lab
set -eu

# --- config: change if needed ---
KUBECONFIG=${KUBECONFIG:-/Users/shrinath.nimbalkar/.kube/config_lab}
NAMESPACE=${NAMESPACE:-monitoring-observability}
PROM_SVC=${PROM_SVC:-monitoring-prometheus}          # service name in your cluster
GRAF_SVC=${GRAF_SVC:-monitoring-grafana}
AM_SVC=${AM_SVC:-monitoring-alertmanager}
PROM_LOCAL_PORT=${PROM_LOCAL_PORT:-9090}
GRAF_LOCAL_PORT=${GRAF_LOCAL_PORT:-18080}
AM_LOCAL_PORT=${AM_LOCAL_PORT:-9093}
# -------------------------------

export KUBECONFIG

pids=()

cleanup() {
  echo
  echo "Stopping port-forwards..."
  for pid in "${pids[@]:-}"; do
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  wait 2>/dev/null || true
  echo "Done."
  exit 0
}

trap cleanup INT TERM

# function to start one forward, background it, and store PID
start_forward() {
  local target=$1 local_port=$2 svc=$3 svc_port=$4 log=$5
  echo "Starting port-forward: localhost:${local_port} -> ${svc}:${svc_port}  (log: ${log})"
  nohup kubectl -n "$NAMESPACE" port-forward "svc/${svc}" "${local_port}:${svc_port}" \
    >"${log}" 2>&1 &
  pid=$!
  pids+=("$pid")
  # small sleep to allow immediate error to show in log
  sleep 0.4
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "Failed to start forward for ${svc}. See ${log}:"
    tail -n +1 "${log}" | sed -n '1,120p'
    cleanup
  fi
}

# start all forwards (service port numbers are standard for these services)
start_forward "prometheus" "$PROM_LOCAL_PORT" "$PROM_SVC" 9090 "/tmp/portfwd-prom.log"
start_forward "grafana"    "$GRAF_LOCAL_PORT" "$GRAF_SVC" 80   "/tmp/portfwd-grafana.log"
start_forward "alertmgr"   "$AM_LOCAL_PORT"   "$AM_SVC"   9093 "/tmp/portfwd-am.log"

echo
echo "Forwards running (press Ctrl-C to stop):"
echo "  Prometheus  -> http://localhost:${PROM_LOCAL_PORT}"
echo "  Grafana     -> http://localhost:${GRAF_LOCAL_PORT}   (user: admin / pass: prom-operator)"
echo "  Alertmanager-> http://localhost:${AM_LOCAL_PORT}"
echo
echo "Logs: /tmp/portfwd-*.log"
echo
# wait on background jobs so this script stays alive in one terminal.
wait

