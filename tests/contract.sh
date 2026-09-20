#!/bin/bash
# Contract tests with a fake Lima executable. These do NOT test Kubernetes/Spark.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/project/.tools/bin"
cp "$ROOT"/0*.sh "$TMP/project/"
cp -R "$ROOT/scripts" "$ROOT/manifests" "$ROOT/config" "$TMP/project/"
cat > "$TMP/project/.tools/bin/limactl" <<'MOCK'
#!/bin/bash
case "$1" in
  --version) echo 'limactl version 2.2.0'; exit 0 ;;
  list)
    case "$*" in
      *Status*) echo "${MOCK_STATE:-Running}" ;;
      *) echo spark-k3s ;;
    esac
    exit 0 ;;
  start) exit 0 ;;
esac
case "$*" in
  *'apply -f -'*) cat >/dev/null; exit 0 ;;
  *'rollout status deployment/spark'*) exit "${MOCK_ROLLOUT_EXIT:-0}" ;;
  *'exec deployment/spark'*'-- python3'*) exit "${MOCK_WORKER_EXIT:-0}" ;;
  *'exec deployment/spark'*'-- timeout'*)
    echo "${MOCK_PI_OUTPUT:-Pi is roughly 3.14159}"
    exit "${MOCK_JOB_EXIT:-0}" ;;
esac
exit 0
MOCK
chmod +x "$TMP/project/.tools/bin/limactl"
count=0
check() {
  expected=$1; pattern=$2; shift 2
  set +e
  "$@" > "$TMP/stdout" 2> "$TMP/stderr"
  actual=$?
  set -e
  [ "$actual" -eq "$expected" ] || { cat "$TMP/stderr"; echo "FAIL: expected $expected got $actual: $*"; exit 1; }
  if [ -n "$pattern" ]; then grep -q "$pattern" "$TMP/stdout" || { echo "FAIL: missing $pattern"; exit 1; }; fi
  if [ "$expected" -ne 0 ]; then
    if grep -Eq '^(SPARK_READY|K8S_READY)' "$TMP/stdout"; then echo 'FAIL: false ready'; exit 1; fi
  fi
  count=$((count + 1))
}
for script in "$TMP/project"/0*.sh; do
  check 0 'Usage:' "$script" --help
  check 2 '' "$script" --invalid
  check 2 '' "$script" --help unexpected
 done
check 0 '^K8S_READY' "$TMP/project/01-start-k8s.sh"
check 0 '^SPARK_READY' "$TMP/project/02-start-spark.sh"
check 0 '^SPARK_READY' "$TMP/project/03-check-spark.sh"
check 1 '' env MOCK_STATE=Stopped "$TMP/project/02-start-spark.sh"
check 1 '' env MOCK_STATE=Stopped "$TMP/project/03-check-spark.sh"
check 1 '' env MOCK_ROLLOUT_EXIT=1 "$TMP/project/03-check-spark.sh"
check 1 '' env MOCK_WORKER_EXIT=1 "$TMP/project/03-check-spark.sh"
check 1 '' env MOCK_JOB_EXIT=124 "$TMP/project/03-check-spark.sh"
check 1 '' env MOCK_PI_OUTPUT='No calculation result' "$TMP/project/03-check-spark.sh"
printf 'PASS: %s mocked contract checks (not an end-to-end test)\n' "$count"
