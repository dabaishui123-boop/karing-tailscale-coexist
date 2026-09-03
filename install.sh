#!/bin/bash

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOURCE_BIN="$SCRIPT_DIR/bin/ktnet"
TARGET_DIR="${HOME}/.local/bin"
TARGET_BIN="$TARGET_DIR/ktnet"
STATE_DIR="${HOME}/.local/state/ktnet/install-backups"

[ -x "$SOURCE_BIN" ] || {
  printf '找不到可执行文件: %s\n' "$SOURCE_BIN" >&2
  exit 1
}

mkdir -p "$TARGET_DIR"

if [ -e "$TARGET_BIN" ] || [ -L "$TARGET_BIN" ]; then
  current_target="$(readlink "$TARGET_BIN" 2>/dev/null || true)"
  if [ "$current_target" = "$SOURCE_BIN" ]; then
    printf '已经安装: %s\n' "$TARGET_BIN"
    exit 0
  fi
  mkdir -p "$STATE_DIR"
  backup_target="$STATE_DIR/ktnet.$(date '+%Y%m%d-%H%M%S')"
  mv "$TARGET_BIN" "$backup_target"
  printf '原文件已移动到: %s\n' "$backup_target"
fi

ln -s "$SOURCE_BIN" "$TARGET_BIN"
printf '安装完成: %s -> %s\n' "$TARGET_BIN" "$SOURCE_BIN"

case ":${PATH}:" in
  *":${TARGET_DIR}:"*) ;;
  *)
    printf '\n请把下面一行加入 ~/.zshrc，然后重新打开终端：\n'
    printf 'export PATH="$HOME/.local/bin:$PATH"\n'
    ;;
esac

printf '\n下一步：%s doctor\n' "$TARGET_BIN"
