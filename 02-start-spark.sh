#!/bin/bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"
HELP='Usage: ./02-start-spark.sh [--help]
Deploy one Spark container with a standalone master and one worker, then verify it.
Requires ./01-start-k8s.sh. Success: SPARK_READY; exit 0. Failure: exit 1. Invalid arguments: exit 2.'
usage "$@"
require_vm
trap 'log "ERROR: Spark deployment failed."; diagnostics; exit 1' ERR
k apply -f - < "$ROOT/manifests/spark.yaml" >&2
k --request-timeout=630s -n "$NAMESPACE" rollout status deployment/spark --timeout=600s >&2
"$ROOT/03-check-spark.sh"
