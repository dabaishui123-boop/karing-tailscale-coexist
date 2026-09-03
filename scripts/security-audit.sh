#!/bin/bash

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

failed=0

while IFS= read -r unsafe_file; do
  [ -n "$unsafe_file" ] || continue
  printf 'FORBIDDEN FILE: %s\n' "$unsafe_file" >&2
  failed=1
done < <(find . -type f \( \
  -name '*.key' -o \
  -name '*.pem' -o \
  -name '.env' -o \
  -name 'karing_setting.json' -o \
  -name 'karing_subscribe*.json' -o \
  -name 'tailscale-status.json' -o \
  -name 'tailscale-prefs.json' \
\) -print)

if command -v rg >/dev/null 2>&1; then
  secret_pattern='(tskey-[A-Za-z0-9_-]+|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)'
  if rg -n --hidden -g '!.git/**' -e "$secret_pattern" .; then
    printf '检测到疑似密钥内容。\n' >&2
    failed=1
  fi
else
  if grep -REn --exclude-dir=.git '(tskey-[A-Za-z0-9_-]+|gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' .; then
    printf '检测到疑似密钥内容。\n' >&2
    failed=1
  fi
fi

if [ "$failed" -ne 0 ]; then
  exit 1
fi

printf 'PASS: 未发现禁止提交的配置文件或常见密钥格式\n'
