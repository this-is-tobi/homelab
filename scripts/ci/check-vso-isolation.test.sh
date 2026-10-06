#!/usr/bin/env bash
# Decision table for scripts/ci/check-vso-isolation.sh on hand-written manifests.
set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/check-vso-isolation.sh"
fail=0

# vss <name> <transformation yaml, indented 6 spaces> -> one VaultStaticSecret
vss() {
  printf -- '---\napiVersion: secrets.hashicorp.com/v1beta1\nkind: VaultStaticSecret\nmetadata:\n  name: %s\nspec:\n  destination:\n    name: %s\n%s\n' "$1" "$1" "$2"
}

good='    transformation:
      excludeRaw: true
      excludes:
      - ".*"
      templates:
        key:
          text: x'

check() { # label expected-exit stdin
  local out rc
  out=$(printf '%s\n' "$3" | "$SCRIPT" --stdin t 2>&1); rc=$?
  if [ "$rc" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: exit $rc, expected $2"; printf '%s\n' "$out" | sed 's/^/     /'; fail=1; fi
}

check "a Secret limited to its templated keys passes" 0 "$(vss ok "$good")"
check "no VaultStaticSecret at all passes" 0 "kind: ConfigMap"
check "a missing excludeRaw is refused" 1 "$(vss raw '    transformation:
      excludes:
      - ".*"
      templates: {}')"
check "excludeRaw false is refused" 1 "$(vss rawfalse '    transformation:
      excludeRaw: false
      excludes:
      - ".*"')"
check "missing excludes is refused" 1 "$(vss noexcl '    transformation:
      excludeRaw: true
      templates: {}')"
check "excludes that do not cover every key are refused" 1 "$(vss narrow '    transformation:
      excludeRaw: true
      excludes:
      - "^admin$"')"
check "no transformation is refused" 1 "$(vss plain '    create: true')"
check "one bad Secret among good ones is refused" 1 "$(vss a "$good")
$(vss b '    create: true')
$(vss c "$good")"

out=$(printf '%s\n' "$(vss leaky '    create: true')" | "$SCRIPT" --stdin chartx 2>&1)
case "$out" in
  *"chartx: leaky:"*) echo "ok   the message names the chart and the Secret" ;;
  *) echo "FAIL the message names the chart and the Secret: $out"; fail=1 ;;
esac

exit "$fail"
