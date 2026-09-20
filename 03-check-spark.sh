#!/bin/bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"
HELP='Usage: ./03-check-spark.sh [--help]
Check Deployment readiness, worker registration, and a real distributed SparkPi job.
Success: SPARK_READY and Pi result; exit 0. Not ready/job failure: exit 1. Invalid arguments: exit 2.'
usage "$@"
require_vm
trap 'log "SPARK_NOT_READY"; diagnostics; exit 1' ERR
k --request-timeout=150s -n "$NAMESPACE" rollout status deployment/spark --timeout=120s >&2
k -n "$NAMESPACE" exec deployment/spark --pod-running-timeout=5s -- python3 -c '
import json, urllib.request, os
s=json.load(urllib.request.urlopen("http://"+os.environ["POD_IP"]+":8080/json/", timeout=5))
assert s["status"] == "ALIVE", s
assert any(w["state"] == "ALIVE" for w in s["workers"]), s
print("MASTER_ALIVE WORKER_REGISTERED")
' >&2
# timeout runs inside Linux, so no GNU timeout/Homebrew is required on macOS.
result=$(k --request-timeout=150s -n "$NAMESPACE" exec deployment/spark --pod-running-timeout=5s -- timeout 120s /bin/bash -c '
exec /opt/spark/bin/spark-submit --master "spark://$POD_IP:7077" \
  --conf spark.driver.host="$POD_IP" --conf spark.driver.bindAddress=0.0.0.0 \
  --conf spark.cores.max=1 --conf spark.executor.memory=512m \
  --conf spark.driver.memory=512m --class org.apache.spark.examples.SparkPi \
  /opt/spark/examples/jars/spark-examples_2.12-3.5.9.jar 10
' 2>&1) || { log "$result"; false; }
pi=$(printf '%s\n' "$result" | grep -E '^Pi is roughly 3\.[0-9]+') || { log "$result"; false; }
printf 'SPARK_READY namespace=%s deployment=spark\n%s\n' "$NAMESPACE" "$pi"
