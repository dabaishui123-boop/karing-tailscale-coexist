#!/bin/bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
EXPECTED_SOURCE="$SCRIPT_DIR/bin/ktnet"
TARGET_BIN="${HOME}/.local/bin/ktnet"

if [ ! -L "$TARGET_BIN" ]; then
  printf '未发现由本仓库安装的符号链接: %s\n' "$TARGET_BIN"
  exit 0
fi

actual_source="$(readlink "$TARGET_BIN")"
if [ "$actual_source" != "$EXPECTED_SOURCE" ]; then
  printf '拒绝删除：%s 指向其他位置 %s\n' "$TARGET_BIN" "$actual_source" >&2
  exit 1
fi

unlink "$TARGET_BIN"
printf '已卸载命令行入口。配置和备份均未删除。\n'
