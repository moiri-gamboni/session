#!/usr/bin/env bash
# Suite for the plugin: bash tests/plugin.test.sh
#
# Case 30: the plugin's manifest and hooks module as Claude Code reads them
# (`claude plugin validate`), and the module's own tests run against Claude
# Code's engine (`claude plugin test`, hooks/*.test.ts). Both need a `claude` on
# PATH, so the suite skips without one.
set -uo pipefail

SUITE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SDIR=$(dirname "$SUITE")

pass=0
fail=0
skipped=0

report() {
    local expect="$1" got="$2" label="$3"
    if [ "$got" = "$expect" ]; then
        pass=$((pass + 1))
        printf 'ok    %s\n' "$label"
    else
        fail=$((fail + 1))
        printf 'FAIL  want=[%s] got=[%s]  %s\n' "$expect" "$got" "$label"
    fi
}
skip() { skipped=$((skipped + 1)); printf 'skip  %s (%s)\n' "$1" "$2"; }

echo "--- case 30: the plugin's hooks module ---"

if ! command -v claude >/dev/null 2>&1; then
    skip "case 30: the plugin's hooks module" "no claude on PATH"
else
    TMP=$(mktemp -d)
    trap 'rm -rf "$TMP"' EXIT
    claude plugin validate "$SDIR" > "$TMP/validate" 2>&1; rc=$?
    report 0 "$rc" "case 30: claude plugin validate accepts the plugin"
    report yes "$(grep -q 'register.ts hooks: session.start, turn.complete, command.run{command=rate-limit-options}' "$TMP/validate" && echo yes || echo no)" \
        "case 30: ... and reads the hooks module as hooking session.start, turn.complete and the usage-limit menu"
    claude plugin test "$SDIR" > "$TMP/test" 2>&1; rc=$?
    sed 's/^/      /' "$TMP/test"
    report 0 "$rc" "case 30: claude plugin test passes the module's tests"
    report 0 "$(grep -cE '^ *[1-9][0-9]* fail' "$TMP/test" || true)" "case 30: ... with no failing test reported"
fi

echo
echo "$pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
