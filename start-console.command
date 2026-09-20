#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if ! command -v ruby >/dev/null; then
  echo 'ERROR: 网页验收需要 Ruby；也可以直接运行三个 Shell 脚本。' >&2
  exit 1
fi
if ! ruby -rwebrick -e '' 2>/dev/null; then
  echo 'ERROR: 当前 Ruby 缺少 WEBrick，请参考 README 的网页依赖说明。' >&2
  exit 1
fi
exec ruby -E UTF-8 console/server.rb
