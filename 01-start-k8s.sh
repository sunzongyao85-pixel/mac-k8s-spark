#!/bin/bash
set -Eeuo pipefail
source "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"
HELP='Usage: ./01-start-k8s.sh [--help]
Install pinned Lima locally and start a 2 CPU / 4 GiB single-node K3s VM.
Success: K8S_READY; exit 0. Failure: stderr diagnostics; exit 1. Invalid arguments: exit 2.'
usage "$@"
startup_error() {
  log "ERROR: Kubernetes startup failed."
  if [ -f "$LIMA_HOME/$INSTANCE/ha.stderr.log" ]; then
    tail -n 12 "$LIMA_HOME/$INSTANCE/ha.stderr.log" >&2
  fi
  exit 1
}
trap startup_error ERR
[ "$(uname -s)" = Darwin ] || fail 'This script requires macOS 13 or newer.'
if ! command -v limactl >/dev/null || [ "$(limactl --version)" != 'limactl version 2.2.0' ]; then
  case "$(uname -m)" in
    arm64) arch=arm64; sha=bbdef91774885a0d05f7b048c4eb89ae2bcf3a0c252ae7ca7934e63df76d93c3 ;;
    x86_64) arch=x86_64; sha=0d6f99c19f6e4bc3c92730c4c29d929e6927f0cb0a0ba1a84383367135a8ff31 ;;
    *) fail 'Unsupported CPU architecture.' ;;
  esac
  mkdir -p "$ROOT/.tools"
  archive=$(mktemp "$ROOT/.tools/lima.XXXXXX")
  trap 'rm -f "$archive"' EXIT
  log 'Downloading Lima 2.2.0 (checksum verified)...'
  curl -fL --retry 3 --connect-timeout 20 --max-time 600 "https://github.com/lima-vm/lima/releases/download/v2.2.0/lima-2.2.0-Darwin-$arch.tar.gz" -o "$archive" >&2
  printf '%s  %s\n' "$sha" "$archive" | shasum -a 256 -c - >&2
  tar -xzf "$archive" -C "$ROOT/.tools"
fi
if limactl list --format '{{.Name}}' 2>/dev/null | grep -qx "$INSTANCE"; then
  limactl start --tty=false --timeout=15m "$INSTANCE" >&2
else
  limactl start --tty=false --name="$INSTANCE" --timeout=15m "$ROOT/config/lima.yaml" >&2
fi
k --request-timeout=210s wait --for=condition=Ready nodes --all --timeout=180s >&2
k --request-timeout=210s -n kube-system wait --for=create deployment/coredns --timeout=180s >&2
k --request-timeout=210s -n kube-system rollout status deployment/coredns --timeout=180s >&2
k get nodes -o wide >&2
printf 'K8S_READY instance=%s\n' "$INSTANCE"
