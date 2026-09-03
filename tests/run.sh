#!/bin/bash

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KTNET="$PROJECT_DIR/bin/ktnet"

bash -n "$KTNET"
bash -n "$PROJECT_DIR/install.sh"
bash -n "$PROJECT_DIR/uninstall.sh"
bash -n "$PROJECT_DIR/scripts/security-audit.sh"

# Parse Windows PowerShell when pwsh is available; otherwise retain portable
# smoke assertions that also run on stock macOS CI hosts.
if command -v pwsh >/dev/null 2>&1; then
  KTNET_PARSE_FILE="$PROJECT_DIR/bin/ktnet.ps1" pwsh -NoProfile -Command '$tokens=$null; $errors=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($env:KTNET_PARSE_FILE,[ref]$tokens,[ref]$errors); if ($errors.Count) { $errors | Format-List | Out-String | Write-Error; exit 1 }'
  pwsh -NoProfile -File "$PROJECT_DIR/bin/ktnet.ps1" help | grep -q 'configure'
  chmod +x "$PROJECT_DIR/tests/fixtures/tailscale.exe" "$PROJECT_DIR/tests/fixtures/Karing.exe"
  windows_plan_output="$(
    PATH="$PROJECT_DIR/tests/fixtures:$PATH" \
    OS=Windows_NT \
    USERPROFILE="${TMPDIR:-/tmp}/ktnet-test-user" \
    KTNET_KARING_APP="$PROJECT_DIR/tests/fixtures/Karing.exe" \
    KTNET_KARING_SETTINGS="$PROJECT_DIR/tests/fixtures/fixture-settings.json" \
    pwsh -NoProfile -File "$PROJECT_DIR/bin/ktnet.ps1" configure --dry-run --extra-route 192.168.50.0/24
  )"
  printf '%s' "$windows_plan_output" | grep -q 'dry-run 通过'
  printf '%s' "$windows_plan_output" | grep -q '100.64.0.0/10'
  printf '%s' "$windows_plan_output" | grep -q 'fd7a:115c:a1e0::/48'
  printf '%s' "$windows_plan_output" | grep -q '192.168.50.0/24'
fi
grep -q 'function Cmd-Configure' "$PROJECT_DIR/bin/ktnet.ps1"
grep -q 'function Restore-BackupInternal' "$PROJECT_DIR/bin/ktnet.ps1"
grep -q 'ktnet-network-guard' "$PROJECT_DIR/bin/ktnet.ps1"
grep -q 'desired-windows.json' "$PROJECT_DIR/bin/ktnet.ps1"

version_output="$($KTNET version)"
[ "$version_output" = 'ktnet 0.1.0' ]

help_output="$($KTNET help)"
printf '%s' "$help_output" | grep -q 'doctor'
printf '%s' "$help_output" | grep -q 'configure'
printf '%s' "$help_output" | grep -q 'restore'

# On a configured Mac this also exercises Bash 3.2 empty-array compatibility
# and confirms an extra subnet is not replaced by a helper's local variable.
if [ "$(uname -s)" = Darwin ] && command -v tailscale >/dev/null 2>&1; then
  plan_output="$($KTNET plan --accept-routes --extra-route 192.168.50.0/24)"
  printf '%s' "$plan_output" | grep -q '100.64.0.0/10'
  printf '%s' "$plan_output" | grep -q 'fd7a:115c:a1e0::/48'
  printf '%s' "$plan_output" | grep -q '192.168.50.0/24'
fi

printf 'PASS: shell syntax, Windows persistence markers, version and help smoke tests\n'
