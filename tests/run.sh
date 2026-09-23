#!/usr/bin/env bash
# Runs every session suite: bash tests/run.sh
#
# Two legs per suite, and the full output of each is printed as it runs.
#
# NATIVE — this machine's bash and this machine's tools. Full coverage.
#
# BASH 3.2 — `docker run --rm -v <repo>:/w -w /w bash:3.2 bash tests/<suite>`,
# the closest thing here to macOS's /bin/bash. It is what catches a bash-4-only
# construct that the host's bash 5 accepts silently, and the reason case 1 also
# greps for the ones no syntax check can see (mapfile, ${v,,}, |&, ;;&,
# $EPOCHSECONDS).
#
#   What the 3.2 leg covers on the stock image: every case needing only bash,
#   busybox coreutils, awk, sed, grep, find and flock — the lint tripwires, the
#   paths and session.conf precedence, realpath_of, mtime_of, the /proc process
#   layer, the flock(1) lock, and the daily prune.
#
#   What it does NOT cover on the stock image: it is Alpine + busybox with no
#   perl, no jq, no timezone database, no GNU date and no GNU find, so the date layer
#   (epoch_of, fmt_epoch, epoch_ms), the perl lock fallback and the login/cache
#   cases print `skip` there — and install.test.sh and statusline.test.sh skip
#   WHOLE (one `skip` line each), both being jq programs with a shell around
#   them, so the stock image proves nothing about the installer or the
#   statusline. busybox `ps` also takes none of the flags the ps fallback uses,
#   so that branch skips in both legs on Linux; it is Darwin-only (see
#   proc_env in lib/common.sh). Every leg prints its own counts as it runs, which is why
#   none are quoted here: a count in a comment is a measurement nothing
#   recomputes, and these went stale twice inside one batch.
#
#   Note the trap the skips exist to avoid: busybox `date` accepts `-d @0` and
#   then parses no relative expression, and an Alpine image without tzdata
#   reports every zone as UTC. A date comparison there would be two identical
#   mistakes agreeing. The suite probes the oracle rather than trusting -d.
#
#   To run every case under bash 3.2, give the runner an image that carries the
#   five missing pieces:
#       printf 'FROM bash:3.2\nRUN apk add --no-cache perl jq tzdata coreutils findutils\n' > /tmp/Dockerfile.b32
#       docker build -t session-tests:bash3.2 -f /tmp/Dockerfile.b32 /tmp
#       SESSION_TEST_IMAGE=session-tests:bash3.2 bash tests/run.sh
#   findutils is not optional there: busybox `find -newer` compares st_mtime
#   alone — whole seconds, nanoseconds never read — so a transcript written in
#   the same second as the title index reads as not newer, the incremental
#   refresh sees no changed files, and five title-index cases fail against code
#   that is correct everywhere else. BSD find, which is what macOS ships,
#   compares the full timespec and does not have the problem, so those failures
#   were the image talking, not the port. Without the package the suite reports
#   them as failures rather than skips, because nothing in the code can detect
#   a find that silently answers a comparison wrong.
#   coreutils puts GNU date at /bin/date and tzdata gives the real zones, so the
#   DST sweep becomes a genuine comparison there; it is also the only place the
#   musl side of the date layer is exercised at all, and the only place that
#   showed musl and glibc normalising a local midnight that does not exist in
#   opposite directions. What still skips there: the ps -Eww fallback (both
#   legs), and in the container only, the ps ppid/cmdline fallback, the
#   ownership case (needs a second uid), the pty case (no script(1) with -qec),
#   the login-switch wait (no inotifywait) and the mode-000 lib case (the
#   container runs as root).
#
# Docker is optional: with no docker or no image the native leg still runs and
# the container leg says why it did not. Exit status is non-zero if any suite
# fails in any leg.
#
#   --require-3.2   a container leg that did not run is a FAILURE, not a skip.
#                   Use it for the acceptance run: the bash 3.2 leg is the port's
#                   only evidence for macOS, and a teammate running the suite
#                   from a fresh clone is exactly who has no image — without this
#                   the run would pass having tested one shell.
set -uo pipefail

require_32=0
for _a in ${1+"$@"}; do
    case "$_a" in
        --require-3.2) require_32=1 ;;
        -h|--help)
            sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)  echo "run.sh: unknown option $_a (try --help)" >&2; exit 2 ;;
    esac
done

SUITE_DIR=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(cd -P "$SUITE_DIR/.." && pwd -P)
IMAGE="${SESSION_TEST_IMAGE:-bash:3.2}"

suites=""
for s in "$SUITE_DIR"/*.test.sh; do
    [ -f "$s" ] && suites="$suites ${s##*/}"
done
[ -n "$suites" ] || { echo "run.sh: no *.test.sh beside this runner" >&2; exit 2; }

# `docker` may need a group the shell was never given (a long-lived shell can
# predate the docker group), so the sg form is tried before giving up.
DOCKER=""
if docker info >/dev/null 2>&1; then
    DOCKER=direct
elif sg docker -c 'docker info >/dev/null 2>&1' >/dev/null 2>&1; then
    DOCKER=sg
fi

dock() {  # dock <docker args...> — through sg when that is what works here
    if [ "$DOCKER" = direct ]; then
        docker "$@"
    else
        local q="" a
        for a in "$@"; do q="$q '$a'"; done
        sg docker -c "docker$q"
    fi
}

failed=0
summary=""
record() {  # LABEL SUITE RC LOGFILE
    local line
    line=$(grep -E '^[0-9]+ passed, [0-9]+ failed' "$4" | sed -n '$p')
    [ -n "$line" ] || line="no summary line — the suite died early"
    if [ "$3" = 0 ]; then
        summary="$summary$(printf '  %-9s %-22s ok    %s' "$1" "$2" "$line")
"
    else
        failed=$((failed + 1))
        summary="$summary$(printf '  %-9s %-22s FAIL  (exit %s) %s' "$1" "$2" "$3" "$line")
"
    fi
}

TMPOUT=$(mktemp -d)
trap 'rm -rf "$TMPOUT"' EXIT

for suite in $suites; do
    echo "===== native: $suite ($(bash --version | sed -n '1p')) ====="
    bash "$SUITE_DIR/$suite" 2>&1 | tee "$TMPOUT/native.$suite"
    record native "$suite" "${PIPESTATUS[0]}" "$TMPOUT/native.$suite"
    echo
done

b32_skip=""
if [ -z "$DOCKER" ]; then
    b32_skip="no usable docker (tried \`docker info\` and \`sg docker -c\`)"
elif ! dock image inspect "$IMAGE" >/dev/null 2>&1; then
    b32_skip="image $IMAGE not present (docker pull $IMAGE)"
fi
if [ -n "$b32_skip" ]; then
    echo "===== bash 3.2: skipped — $b32_skip ====="
    if [ "$require_32" = 1 ]; then
        failed=$((failed + 1))
        summary="$summary$(printf '  %-9s %-22s FAIL  --require-3.2 given, but the leg did not run: %s' 'bash 3.2' '(every suite)' "$b32_skip")
"
    fi
else
    for suite in $suites; do
        echo "===== bash 3.2 ($IMAGE): $suite ====="
        dock run --rm -v "$ROOT":/w -w /w "$IMAGE" bash "tests/$suite" 2>&1 \
            | tee "$TMPOUT/b32.$suite"
        record "bash 3.2" "$suite" "${PIPESTATUS[0]}" "$TMPOUT/b32.$suite"
        echo
    done
fi

echo "===== summary ====="
printf '%s' "$summary"
if [ "$failed" -eq 0 ]; then
    echo "  all suite runs passed"
else
    echo "  $failed suite run(s) failed"
fi
[ "$failed" -eq 0 ]
