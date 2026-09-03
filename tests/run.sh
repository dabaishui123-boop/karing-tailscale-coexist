#!/bin/bash

set -eu

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KTNET="$PROJECT_DIR/bin/ktnet"

bash -n "$KTNET"
bash -n "$PROJECT_DIR/install.sh"
bash -n "$PROJECT_DIR/uninstall.sh"
bash -n "$PROJECT_DIR/scripts/security-audit.sh"

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

printf 'PASS: shell syntax, version and help smoke tests\n'
