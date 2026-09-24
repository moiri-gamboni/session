#!/usr/bin/env bash
# Runs every session suite: bash tests/run.sh
#
# Each *.test.sh beside this runner, with this machine's bash and tools, its
# full output printed as it runs, then a summary. Exit status is non-zero if
# any suite fails. That the shipped scripts stay bash 3.2 clean is checked by
# case 1's lint in session.test.sh, not by running a second shell.
set -uo pipefail

case "${1:-}" in
    '') ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "run.sh: unknown option $1 (try --help)" >&2; exit 2 ;;
esac

SUITE_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

suites=""
for s in "$SUITE_DIR"/*.test.sh; do
    [ -f "$s" ] && suites="$suites ${s##*/}"
done
[ -n "$suites" ] || { echo "run.sh: no *.test.sh beside this runner" >&2; exit 2; }

failed=0
summary=""
TMPOUT=$(mktemp -d)
trap 'rm -rf "$TMPOUT"' EXIT

for suite in $suites; do
    echo "===== $suite ($(bash --version | sed -n '1p')) ====="
    bash "$SUITE_DIR/$suite" 2>&1 | tee "$TMPOUT/$suite"
    rc=${PIPESTATUS[0]}
    line=$(grep -E '^[0-9]+ passed, [0-9]+ failed' "$TMPOUT/$suite" | sed -n '$p')
    [ -n "$line" ] || line="no summary line — the suite died early"
    if [ "$rc" = 0 ]; then
        summary="$summary$(printf '  %-22s ok    %s' "$suite" "$line")
"
    else
        failed=$((failed + 1))
        summary="$summary$(printf '  %-22s FAIL  (exit %s) %s' "$suite" "$rc" "$line")
"
    fi
    echo
done

echo "===== summary ====="
printf '%s' "$summary"
if [ "$failed" -eq 0 ]; then
    echo "  all suites passed"
else
    echo "  $failed suite(s) failed"
fi
[ "$failed" -eq 0 ]
