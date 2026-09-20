#!/bin/bash
# Shared library; public entrypoints are the three scripts at repository root.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LIMA_HOME=${LIMA_HOME:-"$HOME/.lima-mac-spark"}
export PATH="$ROOT/.tools/bin:$PATH"
INSTANCE=spark-k3s
NAMESPACE=spark-demo
log() { printf '%s\n' "$*" >&2; }
fail() { log "ERROR: $*"; exit 1; }
usage() {
  if [ "$#" -gt 1 ]; then log "$HELP"; exit 2; fi
  if [ "$#" -gt 0 ]; then
    case "$1" in
      -h|--help) printf '%s\n' "$HELP"; exit 0 ;;
      *) log "$HELP"; exit 2 ;;
    esac
  fi
}
require_vm() {
  command -v limactl >/dev/null || fail 'Run ./01-start-k8s.sh first.'
  [ "$(limactl list "$INSTANCE" --format '{{.Status}}' 2>/dev/null)" = Running ] || fail 'Kubernetes VM is not running. Run ./01-start-k8s.sh.'
}
k() { limactl shell "$INSTANCE" sudo k3s kubectl --request-timeout=30s "$@"; }
diagnostics() {
  k -n "$NAMESPACE" get pods -o wide >&2 || true
  k -n "$NAMESPACE" get events --sort-by=.lastTimestamp >&2 || true
  k -n "$NAMESPACE" logs deployment/spark --pod-running-timeout=5s --tail=60 >&2 || true
}
