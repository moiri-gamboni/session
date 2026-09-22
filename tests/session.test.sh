#!/usr/bin/env bash
# Suite for the session CLI: bash tests/session.test.sh
#
# Cases 1 and 13 are lint tripwires over every shipped script: no bash-4-only
# construct, no reference to the machine the CLI was first written on, no
# hardcoded home path outside the lib.
#
# Everything expensive is a fixture: the lib is sourced under `env -i` with a
# fake HOME and CLAUDE_CONFIG_DIR so no case can read the real config dir or
# write the real usage store, `jq` is a stub on PATH where a case counts its
# calls, and every fixture lives under mktemp with a trap.
#
# Cases that need a tool the host lacks print `skip` and say which tool. Under
# `docker run bash:3.2` (see run.sh) that is perl and jq: the date layer, the
# perl lock and the login cases skip there, and what runs is the bash-3.2
# compatibility of everything else.
set -uo pipefail

SUITE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SDIR=$(dirname "$SUITE")
LIB="$SDIR/lib/common.sh"
[ -r "$LIB" ] || { echo "lib/common.sh not found beside this suite" >&2; exit 2; }

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
have() { command -v "$1" >/dev/null 2>&1; }

TMP=$(mktemp -d)
FH="$TMP/home"; mkdir -p "$FH"
trap 'rm -rf "$TMP"' EXIT

# The probe: sources the lib under a controlled environment and evaluates $PROBE.
# Callers drive it with `env -i`, so nothing of the outer session's config dir,
# data root or login leaks into a case.
cat > "$TMP/probe" <<'PROBEEOF'
. "$SESSION_LIB_UNDER_TEST" || { echo "cannot source the lib" >&2; exit 9; }
eval "$PROBE"
PROBEEOF

probe() {  # probe 'snippet' [VAR=VAL ...]
    local snippet="$1"; shift
    env -i PATH="$PATH" HOME="$FH" TZ="${TZ:-UTC}" \
        SESSION_LIB_UNDER_TEST="$LIB" PROBE="$snippet" \
        ${1+"$@"} bash "$TMP/probe"
}

echo "--- case 1: syntax and the bash-3.2 tripwire over every shipped script ---"

shipped=""
for f in "$SDIR/session" "$SDIR/statusline.sh" "$SDIR"/lib/*.sh \
         "$SDIR/install.sh" "$SDIR/uninstall.sh"; do
    [ -f "$f" ] && shipped="$shipped $f"
done
report yes "$([ -n "$shipped" ] && echo yes || echo no)" "case 1: some shipped script exists to lint"

for f in $shipped; do
    bash -n "$f" 2>"$TMP/syn" && r=ok || r="FAILED: $(cat "$TMP/syn")"
    report ok "$r" "case 1: bash -n ${f#$SDIR/}"
done

# A shell linter's bash mode flags none of these (probed), so the grep plus
# the bash:3.2 container run is the whole tripwire. $EPOCHSECONDS is bash 5.0,
# mapfile/readarray and declare -A are bash 4.0, ${v,,} is 4.0, |& is 4.0 and
# ;;& is 4.0 — every one of them silently does the wrong thing on macOS's 3.2.
TRIPWIRE='\$EPOCHSECONDS|\bmapfile\b|\breadarray\b|declare -A|\$\{[A-Za-z_][A-Za-z0-9_]*,,|\|&|;;&'
for f in $shipped; do
    n=$(grep -cE "$TRIPWIRE" "$f")
    report 0 "$n" "case 1: no bash-4+ construct in ${f#$SDIR/} (grep -nE '$TRIPWIRE')"
done

echo "--- case 13: the shipped scripts name no host and no home ---"

for f in $shipped; do
    n=$(grep -cE 'ro''ost|RO''OST_|ap''art|AP''ART_' "$f")
    report 0 "$n" "case 13: no host reference in ${f#$SDIR/}"
done
for f in $shipped; do
    case "$f" in */lib/*) continue ;; esac   # the lib is where $HOME/ belongs
    n=$(grep -cE '^[^#]*\$\{?HOME\}?/' "$f")
    report 0 "$n" "case 13: no hardcoded \$HOME path in ${f#$SDIR/}"
done

# ── the lib itself ───────────────────────────────────────────────────────────
# Sourced here so the date, lock, process and prune cases can call the functions
# directly. Every case that cares about the VALUES of the SESSION_* variables
# uses probe() instead, because those are fixed at source time.
# shellcheck source=/dev/null
. "$LIB"

echo "--- lib acceptance: paths and defaults ---"

report "$FH/.claude"                     "$(probe 'printf "%s\n" "$SESSION_CFG"')"       "defaults: SESSION_CFG under a fake HOME"
report "$FH/.claude/session-usage"       "$(probe 'printf "%s\n" "$SESSION_DATA"')"      "defaults: SESSION_DATA"
# The seven per-path basenames are asserted by name in "SESSION_DATA_DIR moves
# every path under the data root" below; with the root pinned here, that case
# covers every default too.
report "$FH/.claude/accounts"            "$(probe 'printf "%s\n" "$SESSION_ACCOUNTS_DIR"')" "defaults: SESSION_ACCOUNTS_DIR"
report "$FH/.claude"                     "$(probe 'printf "%s\n" "$SESSION_PRIMARY_CFG"')"  "defaults: SESSION_PRIMARY_CFG"
report "600"  "$(probe 'printf "%s\n" "$SESSION_ATTEND_GRACE"')"     "defaults: SESSION_ATTEND_GRACE"
report ""     "$(probe 'printf "%s\n" "$SESSION_TMUX_MAIN_GUARD"')"  "defaults: SESSION_TMUX_MAIN_GUARD is empty"
report "8 7"  "$(probe 'printf "%s %s\n" "$SESSION_LIVE_DAYS" "$SESSION_LIVE_FLOOR_DAYS"')" "defaults: retention days and the floor"
report "$FH/.local/bin" "$(probe 'printf "%s\n" "$SESSION_BINDIR_DEFAULT"')" "defaults: SESSION_BINDIR_DEFAULT"
report "0077" "$(probe 'umask')" "sourcing sets umask 077"
report "ok"   "$(probe 'set -u; : "$SESSION_NOW"; echo ok')" "SESSION_NOW is defined (safe under set -u)"

# One knob moves every path under the data root — the property a machine whose
# data lives outside the config dir rests on (the data stays put while the code moves).
D="$TMP/otherdata"
report "$D $D/turn-log.tsv $D/session-log.tsv $D/focus-log.tsv $D/panes $D/sessions $D/archive $D/resume-queue.tsv" \
    "$(probe 'printf "%s %s %s %s %s %s %s %s\n" "$SESSION_DATA" "$SESSION_TLOG" "$SESSION_SLOG" "$SESSION_FLOG" "$SESSION_PANEDIR" "$SESSION_SNAPDIR" "$SESSION_ARCHIVE" "$SESSION_RESUME_QUEUE"' SESSION_DATA_DIR="$D")" \
    "SESSION_DATA_DIR moves every path under the data root"

C="$TMP/altcfg"
report "$C $C/session-usage $C/accounts" \
    "$(probe 'printf "%s %s %s\n" "$SESSION_CFG" "$SESSION_DATA" "$SESSION_ACCOUNTS_DIR"' CLAUDE_CONFIG_DIR="$C")" \
    "CLAUDE_CONFIG_DIR moves the config dir, the data root and the vault"

echo "--- lib acceptance: session.conf ---"

FCFG="$TMP/confcfg"; mkdir -p "$FCFG"
CONFROOT="$TMP/confroot"
cat > "$FCFG/session.conf" <<CONFEOF
SESSION_DATA_DIR="\${SESSION_DATA_DIR:-$CONFROOT}"
SESSION_ATTEND_GRACE="\${SESSION_ATTEND_GRACE:-42}"
SESSION_PRIMARY_CFG="\${SESSION_PRIMARY_CFG:-$FCFG}"
CONFEOF

report "$CONFROOT 42" \
    "$(probe 'printf "%s %s\n" "$SESSION_DATA" "$SESSION_ATTEND_GRACE"' CLAUDE_CONFIG_DIR="$FCFG")" \
    "session.conf sets the data root and the grace when the environment is silent"
report "$D 42" \
    "$(probe 'printf "%s %s\n" "$SESSION_DATA" "$SESSION_ATTEND_GRACE"' CLAUDE_CONFIG_DIR="$FCFG" SESSION_DATA_DIR="$D")" \
    "the environment beats session.conf per variable, and the other conf line still applies"
report "$FH/.claude/session-usage" \
    "$(probe 'printf "%s\n" "$SESSION_DATA"')" \
    "a config dir with no session.conf keeps the defaults"

# L2: the conf is executed verbatim by every hook, every render and every CLI
# call, so a conf anyone else can write is arbitrary code as this user. The
# check is on the FILE, not its directory: both real config dirs on this machine
# are 775, so a directory check would refuse every genuine conf.
chmod 600 "$FCFG/session.conf"
report "$CONFROOT" "$(probe 'printf "%s\n" "$SESSION_DATA"' CLAUDE_CONFIG_DIR="$FCFG")" \
    "a 600 session.conf is read"
chmod 640 "$FCFG/session.conf"
report "$CONFROOT" "$(probe 'printf "%s\n" "$SESSION_DATA"' CLAUDE_CONFIG_DIR="$FCFG")" \
    "a group-READABLE session.conf is still read (the check is about writability)"
chmod 666 "$FCFG/session.conf"
report "$FCFG/session-usage" "$(probe 'printf "%s\n" "$SESSION_DATA"' CLAUDE_CONFIG_DIR="$FCFG" 2>/dev/null)" \
    "a world-writable session.conf is not sourced"
report yes "$(probe 'printf "%s\n" "$SESSION_DATA"' CLAUDE_CONFIG_DIR="$FCFG" 2>&1 >/dev/null | grep -q 'session.conf' && echo yes || echo no)" \
    "... and says so on stderr, naming the file"
chmod 620 "$FCFG/session.conf"
report "$FCFG/session-usage" "$(probe 'printf "%s\n" "$SESSION_DATA"' CLAUDE_CONFIG_DIR="$FCFG" 2>/dev/null)" \
    "a group-writable session.conf is not sourced either"
chmod 600 "$FCFG/session.conf"

echo "--- lib acceptance: session_login is lazy and memoised ---"

STUB="$TMP/stubbin"; mkdir -p "$STUB"
CALLS="$TMP/jq-calls"
cat > "$STUB/jq" <<'JQEOF'
#!/usr/bin/env bash
printf 'call\n' >> "$JQ_CALLS"
printf '%s\n' "${JQ_OUT:-}"
JQEOF
chmod +x "$STUB/jq"

: > "$CALLS"
out=$(env -i PATH="$STUB:$PATH" HOME="$FH" TZ=UTC JQ_CALLS="$CALLS" JQ_OUT="a b@example.com" \
      SESSION_LIB_UNDER_TEST="$LIB" PROBE='printf "sourced=%s\n" "$(wc -l < "$JQ_CALLS" | tr -d " ")"' \
      bash "$TMP/probe")
report "sourced=0" "$out" "sourcing the lib runs no jq at all"

: > "$CALLS"
out=$(env -i PATH="$STUB:$PATH" HOME="$FH" TZ=UTC JQ_CALLS="$CALLS" JQ_OUT="a b@example.com" \
      SESSION_LIB_UNDER_TEST="$LIB" \
      PROBE='session_login; session_login; printf "calls=%s\n" "$(wc -l < "$JQ_CALLS" | tr -d " ")"' \
      bash "$TMP/probe")
report "a_b@example.com
a_b@example.com
calls=1" "$out" "session_login sanitises the email and reads .claude.json once"

: > "$CALLS"
out=$(env -i PATH="$STUB:$PATH" HOME="$FH" TZ=UTC JQ_CALLS="$CALLS" JQ_OUT="" \
      SESSION_LIB_UNDER_TEST="$LIB" PROBE='session_login' bash "$TMP/probe")
report "unknown" "$out" "an empty login reads as unknown"

: > "$CALLS"
out=$(env -i PATH="$STUB:$PATH" HOME="$FH" TZ=UTC JQ_CALLS="$CALLS" JQ_OUT="me@example.com" \
      SESSION_DATA_DIR="$D" SESSION_LIB_UNDER_TEST="$LIB" PROBE='session_cache_path' bash "$TMP/probe")
report "$D/last-status.me@example.com.json" "$out" "session_cache_path keys the cache by login under the data root"

# One definition — an explicit login is sanitised exactly as the live
# one, so acct_limits and the statusline can never key the cache differently.
# `+` survives: it is what separates a login name's organisation suffix.
out=$(env -i PATH="$STUB:$PATH" HOME="$FH" TZ=UTC JQ_CALLS="$CALLS" JQ_OUT="me@example.com" \
      SESSION_DATA_DIR="$D" SESSION_LIB_UNDER_TEST="$LIB" \
      PROBE='session_cache_path "we+ird login@x.com"' bash "$TMP/probe")
report "$D/last-status.we+ird_login@x.com.json" "$out" \
    "session_cache_path sanitises an explicit login like the live one (keeping +)"

# One email, two organisations. A Team or Enterprise seat carries its
# organisation in the login name; a consumer plan keeps the bare email, so
# every login vaulted before the rule keeps its name.
if have jq; then
    TEAMCFG="$TMP/teamcfg"; mkdir -p "$TEAMCFG"
    printf '{"oauthAccount":{"emailAddress":"me@example.com","organizationType":"claude_team","organizationName":"Example Org"}}\n' > "$TEAMCFG/.claude.json"
    report "me@example.com+example-org" "$(probe 'session_login' CLAUDE_CONFIG_DIR="$TEAMCFG")" \
        "session_login names a Team seat <email>+<org slug>"
    report "$D/last-status.me@example.com+example-org.json" \
        "$(probe 'session_cache_path' CLAUDE_CONFIG_DIR="$TEAMCFG" SESSION_DATA_DIR="$D")" \
        "... and the cache follows the login name"
    printf '{"oauthAccount":{"emailAddress":"me@example.com","organizationType":"claude_max","organizationName":"me@example.com'"'"'s Organization"}}\n' > "$TEAMCFG/.claude.json"
    report "me@example.com" "$(probe 'session_login' CLAUDE_CONFIG_DIR="$TEAMCFG")" \
        "a personal Max organisation keeps the bare email"
    printf '{"oauthAccount":{"emailAddress":"me@example.com","organizationType":"claude_enterprise","organizationUuid":"0123abcd-0000"}}\n' > "$TEAMCFG/.claude.json"
    report "me@example.com+0123abcd-0000" "$(probe 'session_login' CLAUDE_CONFIG_DIR="$TEAMCFG")" \
        "an organisation with no name falls back to its uuid"
else
    skip "session_login: same email, two organisations" "no jq"
fi

# The multi-login tag: true whenever the config dir is not ~/.claude, and false
# through a symlink to it (which is the same directory, not another account).
report "nondefault" "$(probe 'session_nondefault_cfg && echo nondefault || echo default' CLAUDE_CONFIG_DIR="$C")" \
    "session_nondefault_cfg is true under a foreign config dir"
# The tag has to mean "not this machine's usual login", not "not ~/.claude":
# against a hardcoded home, every session on a machine whose config lives
# elsewhere is tagged as a secondary account and the tag carries nothing.
report "default" "$(probe 'session_nondefault_cfg && echo nondefault || echo default' CLAUDE_CONFIG_DIR="$C" SESSION_PRIMARY_CFG="$C")" \
    "SESSION_PRIMARY_CFG makes that same config dir the primary one"
report "nondefault" "$(probe 'session_nondefault_cfg && echo nondefault || echo default' SESSION_PRIMARY_CFG="$C")" \
    "...and then ~/.claude is the one that reads as a secondary login"
report "default" "$(probe 'session_nondefault_cfg && echo nondefault || echo default' CLAUDE_CONFIG_DIR="$FCFG")" \
    "a session.conf line can set the primary config dir (the machine-local case)"
mkdir -p "$FH/.claude"
ln -sfn "$FH/.claude" "$TMP/linked-claude"
report "default" "$(probe 'session_nondefault_cfg && echo nondefault || echo default' CLAUDE_CONFIG_DIR="$TMP/linked-claude")" \
    "session_nondefault_cfg resolves symlinks before deciding"
report "default" "$(probe 'session_nondefault_cfg && echo nondefault || echo default')" \
    "session_nondefault_cfg is false for the default config dir"

echo "--- case 11: the date layer against GNU date ---"

# GNU date is the oracle, perl is the implementation. On a machine with neither
# there is nothing to compare, so the case says so instead of passing silently.
# The oracle has to be a real GNU date and a real timezone database, and both
# have to be checked: busybox date accepts `-d @0` while parsing no relative
# expression, and an Alpine image without tzdata reports every zone as UTC, so
# either one would turn this case into a comparison of two identical mistakes.
oracle=yes
have perl || oracle="no perl"
[ "$oracle" = yes ] && { date -d @0 +%F >/dev/null 2>&1 || oracle="no date -d"; }
[ "$oracle" = yes ] && { [ "$(date -d '2026-03-08 +1 day' +%F 2>/dev/null)" = 2026-03-09 ] || oracle="date(1) parses no relative dates (busybox?)"; }
[ "$oracle" = yes ] && { [ "$(date -d '2026-03-08 00:00 1 day ago' +%F 2>/dev/null)" = 2026-03-07 ] || oracle="date(1) parses no 'N ago' (busybox?)"; }
[ "$oracle" = yes ] && { [ "$(TZ=Europe/Zurich date -d @1774742400 +%Z)" = CET ] || oracle="no timezone database — every zone reads as UTC"; }
[ "$oracle" = yes ] && { [ "$(TZ=Europe/Zurich perl -MPOSIX -e 'print POSIX::strftime("%Z", localtime(1774742400))')" = CET ] || oracle="perl sees no timezone database"; }

if [ "$oracle" != yes ]; then
    skip "case 11: epoch_of/fmt_epoch" "$oracle"
else
    # Deterministic, so a failure is reproducible: the seed is fixed, and the
    # list carries the 2026 DST transitions of all three zones plus their
    # neighbours, which random dates would hit only by luck.
    RANDOM=20260831
    dates="2026-03-08 2026-03-09 2026-03-28 2026-03-29 2026-03-30 2026-04-04 2026-04-05
           2026-10-03 2026-10-04 2026-10-24 2026-10-25 2026-10-26 2026-11-01 2026-11-02"
    i=0
    while [ "$i" -lt 30 ]; do
        n=$(( 1704067200 + (RANDOM * 32768 + RANDOM) % 126230400 ))
        dates="$dates $(date -u -d "@$n" +%F)"
        i=$(( i + 1 ))
    done
    # Fixed instants for the now-relative shapes: noon on each transition day
    # (unambiguous in every zone) plus a spread of others.
    nows=""
    for d in 2026-03-08 2026-03-29 2026-04-05 2026-10-04 2026-10-25 2026-11-01 \
             2025-01-15 2025-06-30 2026-02-28 2026-12-31 2027-07-04 2024-02-29; do
        nows="$nows $(date -u -d "$d 12:00" +%s)"
    done

    OLDTZ="${TZ:-}"
    for z in Europe/Zurich America/New_York Australia/Lord_Howe; do
        export TZ="$z"
        bad_mid=0; bad_next=0; nonexistent=0
        for d in $dates; do
            if ! exp=$(date -d "$d 00:00" +%s 2>/dev/null); then
                # GNU date refuses a local midnight that does not exist on a DST
                # day; perl's mktime answers with the shifted hour, which is the
                # better answer, so the pair is reported rather than asserted.
                nonexistent=$(( nonexistent + 1 ))
                printf '      note: %s %s 00:00 does not exist locally; GNU date refuses, epoch_of says %s\n' \
                    "$z" "$d" "$(epoch_of "$d 00:00")"
                continue
            fi
            got=$(epoch_of "$d 00:00")
            [ "$got" = "$exp" ] || { bad_mid=$((bad_mid+1)); printf '      diverge %s %s 00:00: perl=%s gnu=%s\n' "$z" "$d" "$got" "$exp"; }
            exp=$(date -d "$d +1 day" +%s)
            got=$(epoch_of "$d +1 day")
            [ "$got" = "$exp" ] || { bad_next=$((bad_next+1)); printf '      diverge %s %s +1 day: perl=%s gnu=%s\n' "$z" "$d" "$got" "$exp"; }
        done
        report 0 "$bad_mid"  "case 11 [$z]: 'YYYY-MM-DD 00:00' matches GNU date over $(set -- $dates; echo $#) dates"
        report 0 "$bad_next" "case 11 [$z]: 'YYYY-MM-DD +1 day' matches GNU date (DST days are 23h/25h)"
        [ "$nonexistent" = 0 ] || skip "case 11 [$z]: $nonexistent nonexistent local midnights" "GNU date refuses them"

        bad_today=0; bad_ymid=0; bad_y=0
        for n in $nows; do
            SESSION_NOW="$n"
            day=$(date -d "@$n" +%F)
            stamp=$(date -d "@$n" +'%F %T')
            exp=$(date -d "$day 00:00" +%s);            got=$(epoch_of '00:00')
            [ "$got" = "$exp" ] || { bad_today=$((bad_today+1)); printf '      diverge %s now=%s 00:00: perl=%s gnu=%s\n' "$z" "$n" "$got" "$exp"; }
            exp=$(date -d "$day 00:00 1 day ago" +%s); got=$(epoch_of 'yesterday 00:00')
            [ "$got" = "$exp" ] || { bad_ymid=$((bad_ymid+1)); printf '      diverge %s now=%s yesterday 00:00: perl=%s gnu=%s\n' "$z" "$n" "$got" "$exp"; }
            exp=$(date -d "$stamp 1 day ago" +%s);      got=$(epoch_of 'yesterday')
            [ "$got" = "$exp" ] || { bad_y=$((bad_y+1)); printf '      diverge %s now=%s yesterday: perl=%s gnu=%s\n' "$z" "$n" "$got" "$exp"; }
        done
        # shellcheck disable=SC2034  # read by now_epoch(), which lives in the sourced lib
        SESSION_NOW=""
        report 0 "$bad_today" "case 11 [$z]: '00:00' is today's local midnight for a fixed SESSION_NOW"
        report 0 "$bad_ymid"  "case 11 [$z]: 'yesterday 00:00' is the previous local day's midnight"
        report 0 "$bad_y"     "case 11 [$z]: 'yesterday' keeps the time of day across a DST change"

        bad_fmt=0
        for n in $nows; do
            for f in '%F' '%H:%M' '%H:%M %Z' '%Y-%m-%d %H:%M %Z'; do
                exp=$(date -d "@$n" +"$f"); got=$(fmt_epoch "$n" "$f")
                [ "$got" = "$exp" ] || { bad_fmt=$((bad_fmt+1)); printf '      diverge %s fmt %s of %s: perl=[%s] gnu=[%s]\n' "$z" "$f" "$n" "$got" "$exp"; }
            done
        done
        report 0 "$bad_fmt" "case 11 [$z]: fmt_epoch matches date -d @N for the four formats"
    done
    if [ -n "$OLDTZ" ]; then export TZ="$OLDTZ"; else unset TZ; fi

    # The skip branch above fires only where a local midnight does not exist, and
    # none of the three zones has one (all transition at 02:00). This is its
    # positive control: Chile moves the clock AT midnight, so 2026-09-06 00:00
    # never happens there. GNU date refuses outright — which would make
    # `session time --date 2026-09-06` fail there — while mktime answers with the
    # instant next to the missing one and the day is still readable. WHICH side
    # it lands on is the C library's choice, not ours: glibc normalises forward
    # to 01:00, musl back to 23:00 the day before (both observed 2026-08-31), so
    # the assertion is that it answers at all, within the hour.
    ( export TZ=America/Santiago
      gnu_rc=$(date -d '2026-09-06 00:00' +%s >/dev/null 2>&1; echo $?)
      got=$(epoch_of '2026-09-06 00:00')
      case "$(fmt_epoch "$got" '%F %H:%M')" in
        "2026-09-06 01:00") near="forward (glibc)" ;;
        "2026-09-05 23:00") near="back (musl)" ;;
        *)                  near="$(fmt_epoch "$got" '%F %H:%M')" ;;
      esac
      printf 'gnu_rc=%s answered=%s\n' "$gnu_rc" "$([ -n "$got" ] && echo yes || echo no)"
      printf '      note: this libc normalises the missing midnight %s\n' "$near" >&2
    ) > "$TMP/santiago" 2>&1
    report "gnu_rc=1 answered=yes" "$(grep '^gnu_rc' "$TMP/santiago")" \
        "case 11: where local midnight does not exist, GNU date refuses and epoch_of still answers"
    grep '^      note:' "$TMP/santiago"

    # L1: mktime normalises out-of-range fields, so without a check a typo'd
    # --date answers about a different day. GNU date refuses these outright, and
    # so must the port — a wrong day reported confidently is the failure this
    # whole port names as its target.
    for bad in '2026-02-30 00:00' '2026-13-45 00:00' '2025-02-29 00:00' '2026-04-31 00:00'; do
        report 2 "$( ( epoch_of "$bad" >/dev/null 2>&1 ); echo $? )" \
            "case 11: '$bad' refuses (mktime would answer about another day)"
    done
    for good in '2026-02-28 00:00' '2024-02-29 00:00' '2026-12-31 00:00'; do
        report yes "$(epoch_of "$good" | grep -qE '^[0-9]+$' && echo yes || echo no)" \
            "case 11: '$good' is a real date and still resolves"
    done
    report "$(date -d '2026-03-01 00:00' +%s)" "$(epoch_of '2026-02-28 +1 day')" \
        "case 11: the +1 day arm validates the date it was given, not the day after it"
    refusal=$( ( epoch_of '2026-02-30 00:00' ) 2>&1 >/dev/null )
    report yes "$(printf '%s' "$refusal" | grep -q 'YYYY-MM-DD 00:00' && echo yes || echo no)" \
        "case 11: ... through the same refusal that names the accepted shapes"
    report yes "$( ( epoch_of 'three fridays hence' >/dev/null 2>&1 ); [ $? -ne 0 ] && echo yes || echo no )" \
        "case 11: GNU date's refusal of unparseable free text propagates (the CLI turns it into exit 2)"

    # BSD date's -d sets the DST flag rather than parsing a date, so on macOS free
    # text must refuse instead of answering with a wrong day. The stub is that
    # date: it rejects -d and passes everything else through.
    DSTUB="$TMP/datestub"; mkdir -p "$DSTUB"
    printf '#!/bin/sh\ncase "${1:-}" in -d) exit 1;; esac\nexec %s "$@"\n' "$(command -v date)" > "$DSTUB/date"
    chmod +x "$DSTUB/date"
    rc=$( PATH="$DSTUB:$PATH"; ( epoch_of '3 days ago 00:00' >/dev/null 2>&1 ); echo $? )
    msg=$( PATH="$DSTUB:$PATH"; ( epoch_of '3 days ago 00:00' ) 2>&1 >/dev/null )
    report 2 "$rc" "case 11: without GNU date, free text exits 2 rather than guessing"
    report yes "$(printf '%s' "$msg" | grep -q "YYYY-MM-DD 00:00" && echo yes || echo no)" \
        "case 11: ... and the refusal names the shapes it does accept"
    report "$(date -d '2026-08-01 00:00' +%s)" "$( PATH="$DSTUB:$PATH"; epoch_of '2026-08-01 00:00' )" \
        "case 11: the named shapes still work without GNU date"
fi

# now_epoch and epoch_ms
report "1787000000" "$(SESSION_NOW=1787000000 bash -c ". \"$LIB\"; now_epoch")" "now_epoch honours SESSION_NOW"
n1=$(now_epoch); n2=$(date +%s)
report yes "$([ "$n1" -ge $(( n2 - 2 )) ] && [ "$n1" -le $(( n2 + 2 )) ] && echo yes || echo no)" \
    "now_epoch without SESSION_NOW is the wall clock"
if have perl; then
    ms=$(epoch_ms)
    report yes "$(printf '%s' "$ms" | grep -qE '^[0-9]{10}\.[0-9]{3}$' && echo yes || echo no)" \
        "epoch_ms prints seconds with milliseconds (never a literal %3N)"
else
    skip "epoch_ms" "no perl"
fi

echo "--- case 12: lock_run ---"

LOCKF="$TMP/lock"
# Runs two callers against one lock and leaves the second one's status in
# $TMP/second.rc. Not called inside a command substitution: the report lines are
# the suite's output and the counters are the suite's own.
lock_case() {  # $1=label $2=PATH for the callers
    local label="$1" p="$2" holder_rc i hpid
    rm -f "$TMP/holder.ran" "$TMP/holder.rc" "$TMP/second.rc" "$LOCKF"
    ( PATH="$p"; lock_run "$LOCKF" sh -c "touch '$TMP/holder.ran'; sleep 3"; echo $? > "$TMP/holder.rc" ) &
    hpid=$!
    i=0
    while [ ! -e "$TMP/holder.ran" ] && [ "$i" -lt 10 ]; do sleep 1; i=$(( i + 1 )); done
    ( PATH="$p"; lock_run "$LOCKF" true; echo $? > "$TMP/second.rc" )
    wait "$hpid"
    holder_rc=$(cat "$TMP/holder.rc" 2>/dev/null)
    report yes "$([ -e "$TMP/holder.ran" ] && echo yes || echo no)" "case 12 [$label]: the holder ran"
    report 0 "$holder_rc" "case 12 [$label]: the holder exits with its command's status"
}

# The perl fallback, which is what macOS runs: flock(1) is hidden by giving the
# callers a PATH with everything but it. This is the case that pins $^F=10 —
# without it perl closes the lock fd at exec, both callers run, and the second
# exits 0.
if have perl; then
    MINI="$TMP/minbin"; mkdir -p "$MINI"
    for t in perl sh sleep touch true cat rm; do
        p=$(command -v "$t") && ln -sf "$p" "$MINI/$t"
    done
    if PATH="$MINI" command -v flock >/dev/null 2>&1; then
        skip "case 12 [perl]" "flock is still on the minimal PATH"
    else
        lock_case perl "$MINI"
        report 75 "$(cat "$TMP/second.rc" 2>/dev/null)" \
            "case 12 [perl]: a second caller exits 75 while the lock is held (this is what pins \$^F=10)"
    fi
else
    skip "case 12 [perl]" "no perl"
fi

if have flock; then
    lock_case "flock(1)" "$PATH"
    rc=$(cat "$TMP/second.rc" 2>/dev/null)
    # Non-zero, not a specific code: the two flock builds report busy differently
    # (util-linux 1, busybox 1, and 69/255 respectively when the command cannot
    # be run), and the one caller distinguishes only zero from non-zero.
    report yes "$([ -n "$rc" ] && [ "$rc" != 0 ] && echo yes || echo no)" \
        "case 12 [flock(1)]: a busy lock is non-zero (got $rc)"
else
    skip "case 12 [flock(1)]" "no flock"
fi

# H1: a locked command that cannot be EXECUTED must not report success. The
# prune reads a 0 as "awk ran and the tmp is a valid replacement" and moves that
# tmp over the live log, so a backend that returns 0 here empties the store.
# exec fails for more than a missing file — EACCES, ENOEXEC, ETXTBSY, ENOMEM.
# The broken awk is a file with no execute bit rather than a dangling symlink,
# and NO working awk is on these PATHs: execvp skips an ENOENT entry and keeps
# searching, so a dangling one earlier in PATH proves nothing.
BROKEN="$TMP/brokenbin"; mkdir -p "$BROKEN"
printf '#!/bin/sh\nexit 0\n' > "$BROKEN/awk"; chmod 000 "$BROKEN/awk"
FULLBIN="$TMP/fullbin"; mkdir -p "$FULLBIN"
for t in bash sh sed grep touch mv rm find cat stat ls mkdir date tr perl true sleep; do
    p=$(command -v "$t") && ln -sf "$p" "$FULLBIN/$t"
done

exec_fail_rc() {  # $1=PATH for the caller -> the status lock_run reported
    rm -f "$LOCKF"
    ( PATH="$1"; lock_run "$LOCKF" "$BROKEN/awk" -v x=1 'BEGIN{}' </dev/null >/dev/null 2>&1; echo $? )
}

# The same fault through the prune: the live logs are the thing at stake.
prune_exec_fail() {  # $1=label $2=PATH
    local root="$TMP/execfail.$1"
    rm -rf "$root"; mkdir -p "$root"
    local o=$(( PRUNE_NOW - 10 * 86400 )) n=$(( PRUNE_NOW - 86400 ))
    local lg
    for lg in turn-log session-log focus-log; do
        printf '%s\tsid\told\n%s\tsid\tnew\n' "$o" "$n" > "$root/$lg.tsv"
    done
    probe 'session_prune_daily' SESSION_DATA_DIR="$root" SESSION_NOW="$PRUNE_NOW" PATH="$2" >/dev/null 2>&1
    report 2 "$(wc -l < "$root/turn-log.tsv" | tr -d ' ')" \
        "case 12 [$1]: a prune whose awk cannot be executed leaves the live turn log intact"
    report 2 "$(wc -l < "$root/session-log.tsv" | tr -d ' ')" \
        "case 12 [$1]: ... and the session log"
    report absent "$([ -s "$root/archive/turn-log.tsv" ] && echo present || echo absent)" \
        "case 12 [$1]: ... and archives nothing"
    rm -rf "$root"
}

PRUNE_NOW=$(date +%s)
if have perl; then
    if PATH="$FULLBIN" command -v flock >/dev/null 2>&1; then
        skip "case 12 [perl]: exec failure" "flock is on the minimal PATH"
    else
        report 127 "$(exec_fail_rc "$FULLBIN")" \
            "case 12 [perl]: a locked command that cannot be executed reports 127, not success"
        prune_exec_fail perl "$BROKEN:$FULLBIN"
    fi
else
    skip "case 12 [perl]: exec failure" "no perl"
fi
if have flock; then
    FLOCKBIN="$TMP/flockbin"; mkdir -p "$FLOCKBIN"
    for t in bash sh sed grep touch mv rm find cat stat ls mkdir date tr flock true sleep; do
        p=$(command -v "$t") && ln -sf "$p" "$FLOCKBIN/$t"
    done
    rc=$(exec_fail_rc "$FLOCKBIN")
    report yes "$([ "$rc" != 0 ] && echo yes || echo no)" \
        "case 12 [flock(1)]: a locked command that cannot be executed reports non-zero (got $rc)"
    prune_exec_fail "flock(1)" "$BROKEN:$FLOCKBIN"
else
    skip "case 12 [flock(1)]: exec failure" "no flock"
fi

# M1: two producers prune the same root — the statusline on every render and
# `session --session-end`. They must not share a temp file name: the redirect is
# applied by the caller's shell BEFORE the lock is tested, so a shared name lets
# the loser truncate the winner's file in flight and then delete it. The
# signature of that loss is rows present in BOTH the live log and the archive,
# which every later `session time --date` on an archived day double-counts.
echo "--- M1: concurrent prunes ---"
RACE_OLD=40000
RACE_NEW=5
RACE_PAIRS="${SESSION_TEST_RACE_PAIRS:-25}"
if [ "$RACE_PAIRS" = 0 ]; then
    skip "M1: concurrent prunes" "SESSION_TEST_RACE_PAIRS=0"
else
    RD="$TMP/race"; mkdir -p "$RD"
    # One template, copied per pair: building 40k rows 25 times would dominate.
    awk -v o=$(( PRUNE_NOW - 10 * 86400 )) -v n=$(( PRUNE_NOW - 86400 )) \
        -v old="$RACE_OLD" -v new="$RACE_NEW" \
        'BEGIN { for (i = 0; i < old; i++) printf "%s\tsid\told\n", o
                 for (i = 0; i < new; i++) printf "%s\tsid\tnew\n", n }' > "$RD/template.tsv"
    anomalies=0
    i=0
    while [ "$i" -lt "$RACE_PAIRS" ]; do
        rm -rf "$RD/root"; mkdir -p "$RD/root"
        cp "$RD/template.tsv" "$RD/root/turn-log.tsv"
        probe 'session_prune_daily' SESSION_DATA_DIR="$RD/root" SESSION_NOW="$PRUNE_NOW" >/dev/null 2>&1 &
        a=$!
        probe 'session_prune_daily' SESSION_DATA_DIR="$RD/root" SESSION_NOW="$PRUNE_NOW" >/dev/null 2>&1 &
        b=$!
        wait "$a" "$b"
        live=$(wc -l < "$RD/root/turn-log.tsv" | tr -d ' ')
        arch=0
        [ -s "$RD/root/archive/turn-log.tsv" ] && arch=$(wc -l < "$RD/root/archive/turn-log.tsv" | tr -d ' ')
        if [ "$live" != "$RACE_NEW" ] || [ "$arch" != "$RACE_OLD" ]; then
            anomalies=$(( anomalies + 1 ))
            printf '      anomaly: live=%s (want %s) archive=%s (want %s)\n' "$live" "$RACE_NEW" "$arch" "$RACE_OLD"
        fi
        i=$(( i + 1 ))
    done
    report 0 "$anomalies" "M1: $RACE_PAIRS concurrent prune pairs leave no row in both the live log and the archive"
    rm -rf "$RD"
fi

echo "--- lib acceptance: the process layer ---"

report "$PPID" "$(proc_ppid $$)" "proc_ppid of this shell is \$PPID"
report 1 "$( (proc_ppid 0 >/dev/null 2>&1); echo $? )" "proc_ppid of a pid that cannot exist fails"

env SESSION_TEST_MARK=hello-marker sleep 30 &
kid=$!
sleep 1
report yes "$(proc_cmdline "$kid" | tr '\n' ' ' | grep -q 'sleep 30' && echo yes || echo no)" \
    "proc_cmdline gives one argv word per line"
report "hello-marker" "$(proc_env "$kid" SESSION_TEST_MARK)" "proc_env reads a variable out of another process"
report "" "$(proc_env "$kid" SESSION_TEST_NOT_SET)" "proc_env is empty for a variable that is not set"

# The ps branch — what runs on macOS. session_have_proc is overridden rather than
# faked away so the same code path is exercised on a machine that has /proc.
if ps -o ppid= -p $$ >/dev/null 2>&1; then
    report "$PPID" "$( session_have_proc() { return 1; }; proc_ppid $$ )" \
        "proc_ppid falls back to ps"
    report yes "$( session_have_proc() { return 1; }; proc_cmdline "$kid" | tr '\n' ' ' | grep -q 'sleep' && echo yes || echo no )" \
        "proc_cmdline falls back to ps"
else
    skip "proc_* ps fallback" "this ps does not take -o ppid= -p"
fi
if ps -Eww -o command= -p $$ >/dev/null 2>&1; then
    report "hello-marker" "$( session_have_proc() { return 1; }; proc_env "$kid" SESSION_TEST_MARK )" \
        "proc_env falls back to ps -Eww"
else
    skip "proc_env ps -Eww fallback" "this ps rejects -E; the branch is Darwin-only and unverified here"
fi
kill "$kid" 2>/dev/null
wait "$kid" 2>/dev/null

echo "--- lib acceptance: files ---"

echo hi > "$TMP/real-file"
report "$(stat -c %Y "$TMP/real-file" 2>/dev/null || stat -f %m "$TMP/real-file")" "$(mtime_of "$TMP/real-file")" \
    "mtime_of reads a modification time"
report 1 "$( (mtime_of "$TMP/nope" >/dev/null 2>&1); echo $? )" "mtime_of fails on a missing file"

mkdir -p "$TMP/realdir/sub"
ln -sfn "$TMP/realdir" "$TMP/dirlink"
ln -sf "$TMP/real-file" "$TMP/abslink"
( cd "$TMP" && ln -sf real-file rellink )
report "$TMP/real-file" "$(realpath_of "$TMP/real-file")" "realpath_of leaves a real path alone"
report "$TMP/real-file" "$(realpath_of "$TMP/abslink")"   "realpath_of follows an absolute symlink"
report "$TMP/real-file" "$(realpath_of "$TMP/rellink")"   "realpath_of follows a relative symlink"
report "$TMP/realdir/sub" "$(realpath_of "$TMP/dirlink/sub")" "realpath_of resolves a symlinked parent directory"
report "$TMP/no-such-dir/x" "$(realpath_of "$TMP/no-such-dir/x")" "realpath_of leaves an unresolvable path unchanged"
report "/" "$(realpath_of /)" "realpath_of handles the root directory"
# L4: cd consults CDPATH for any operand not starting with / or . — and ECHOES
# the directory it landed in, so a poisoned CDPATH both misresolves the path and
# adds a line to the captured output.
mkdir -p "$TMP/cdtrap/sub" "$TMP/cdreal/sub"
: > "$TMP/cdreal/sub/file"
report "$TMP/cdreal/sub/file" "$( cd "$TMP/cdreal" && CDPATH="$TMP/cdtrap" realpath_of sub/file )" \
    "realpath_of ignores CDPATH"

echo "--- lib acceptance: session_prune_daily ---"

# Anchored to the real clock: the marker's mtime is a real file time, so a fake
# "now" in the past would make the once-a-day check read as "pruned in the future".
NOW=$(date +%s)
PR="$TMP/pruneroot"
mkdir -p "$PR/sessions" "$PR/panes"
old=$(( NOW - 10 * 86400 ))     # past the 8-day horizon
new=$(( NOW - 1 * 86400 ))
for lg in turn-log session-log focus-log; do
    printf '%s\tsid\told\n%s\tsid\tnew\n' "$old" "$new" > "$PR/$lg.tsv"
done
touch -t 202001010000 "$PR/sessions/stale.json" "$PR/panes/stale"
touch "$PR/sessions/fresh.json" "$PR/panes/fresh"

probe 'session_prune_daily' SESSION_DATA_DIR="$PR" SESSION_NOW="$NOW"
report yes "$([ -e "$PR/.session-log-pruned" ] && echo yes || echo no)" "prune: the marker is written"
report "$new	sid	new" "$(cat "$PR/turn-log.tsv")"    "prune: the live turn log keeps only rows inside the horizon"
report "$old	sid	old" "$(cat "$PR/archive/turn-log.tsv")" "prune: older rows move to the archive"
report "$new	sid	new" "$(cat "$PR/session-log.tsv")" "prune: the session log is pruned too"
report "$new	sid	new" "$(cat "$PR/focus-log.tsv")"   "prune: the focus log is pruned too"
report "absent" "$([ -e "$PR/sessions/stale.json" ] && echo present || echo absent)" "prune: dead session snapshots are swept"
report "present" "$([ -e "$PR/sessions/fresh.json" ] && echo present || echo absent)" "prune: live session snapshots survive"
report "absent" "$([ -e "$PR/panes/stale" ] && echo present || echo absent)" "prune: dead pane entries are swept"
report "present" "$([ -e "$PR/panes/fresh" ] && echo present || echo absent)" "prune: live pane entries survive"
report "absent" "$(ls "$PR"/*.tmp* >/dev/null 2>&1 && echo present || echo absent)" "prune: no temp file is left behind"

# Once a day: a second call the same day must not touch the logs, which is what
# keeps the statusline's per-render cost at two stats.
printf '%s\tsid\tsecond-old\n' "$old" >> "$PR/turn-log.tsv"
probe 'session_prune_daily' SESSION_DATA_DIR="$PR" SESSION_NOW="$NOW"
report yes "$(grep -q 'second-old' "$PR/turn-log.tsv" && echo yes || echo no)" \
    "prune: a second call inside 24h does nothing"
probe 'session_prune_daily' SESSION_DATA_DIR="$PR" SESSION_NOW="$(( NOW + 86401 ))"
report no "$(grep -q 'second-old' "$PR/turn-log.tsv" && echo yes || echo no)" \
    "prune: a call a day later prunes again"

EMPTY="$TMP/emptyroot"
report "0 absent" \
    "$(probe 'session_prune_daily; printf "%s %s\n" "$?" "$([ -d "$SESSION_DATA" ] && echo present || echo absent)"' SESSION_DATA_DIR="$EMPTY" SESSION_NOW="$NOW")" \
    "prune: no data root means exit 0 and nothing created"


# ═══════════════════════════════════════════════════════════════════════════════
# The CLI itself. Every case runs `session` as a subprocess under `env -i` with a
# fixture config dir and data root, so nothing here can read the real store or
# the real login. CLAUDE_CODE_SESSION_ID is always set explicitly: this suite
# runs INSIDE a Claude Code session, whose ancestors export it, and resolve_sid's
# ancestor walk would otherwise reach the real session and pass for the wrong
# reason.
# ═══════════════════════════════════════════════════════════════════════════════

BIN="$SDIR/session"
UUID=11111111-1111-1111-1111-111111111111
UUID2=99999999-9999-9999-9999-999999999999

world() {  # -> a fresh fixture world: $w/cfg (config dir) + $w/data (data root)
    local w
    w=$(mktemp -d "$TMP/w.XXXXXX")
    mkdir -p "$w/cfg/sessions" "$w/data/sessions" "$w/data/panes"
    printf '%s\n' "$w"
}

# sess WORLD [VAR=VAL ...] -- <session args>
# The env assignments land after the defaults, and `env` lets a later assignment
# win, so a case can override PATH, the session id, the grace, anything.
sess() {
    local w=$1; shift
    local e=""
    while [ $# -gt 0 ] && [ "$1" != -- ]; do e="$e $1"; shift; done
    [ "${1:-}" = -- ] && shift
    env -i PATH="$PATH" HOME="$FH" TZ="${TZ:-UTC}" \
        CLAUDE_CONFIG_DIR="$w/cfg" SESSION_DATA_DIR="$w/data" \
        SESSION_ACCOUNTS_DIR="$w/cfg/accounts" \
        SESSION_RESUME_QUEUE="$w/data/resume-queue.tsv" \
        CLAUDE_CODE_SESSION_ID="$UUID" \
        $e timeout 60 bash "$BIN" "$@"
}

# A statusline cache for one login. Percentages and reset stamps are arguments
# because the guard, the stale branches and the warn gate all key on them.
mkcache() {  # WORLD LOGIN FIVE% WEEK% FIVE_RESET WEEK_RESET
    printf '{"rate_limits":{"five_hour":{"used_percentage":%s,"resets_at":%s},"seven_day":{"used_percentage":%s,"resets_at":%s}},"context_window":{"used_percentage":42},"model":{"display_name":"Fable 5"},"version":"2.1.233"}\n' \
        "$3" "$5" "$4" "$6" > "$1/data/last-status.$2.json"
}
mklogin() {  # WORLD EMAIL — the config dir's identity, which keys the cache
    printf '{"oauthAccount":{"emailAddress":"%s"}}\n' "$2" > "$1/cfg/.claude.json"
}

# A PATH holding the usual tools MINUS one, for the "this host has no tmux"
# branches. Symlinks, so the excluded name is genuinely unreachable.
minipath() {  # EXCLUDED -> bin dir
    local ex="$1" d t p
    d=$(mktemp -d "$TMP/bin.XXXXXX")
    for t in bash sh env timeout jq perl sed awk gawk mawk grep egrep cut sort tr \
             find ls cat rm mkdir mv cp touch stat date column pgrep sleep chmod \
             id ln wc basename dirname uname flock; do
        [ "$t" = "$ex" ] && continue
        p=$(command -v "$t" 2>/dev/null) || continue
        case "$p" in /*) ln -sf "$p" "$d/$t" ;; esac
    done
    printf '%s\n' "$d"
}

# A curl that answers the usage endpoint from files instead of the network:
# body.<token> is the response body and status.<token> its HTTP status (200
# when there is no status file, 000 for a transport failure — what real curl
# reports when no response arrived). It notes every token it was asked with in
# asked.<token> and logs its argv, which is what makes "the token never rides
# argv" checkable. %{http_code} is written only when -w asks for that exact
# field, so a changed format reads as a missing status rather than as one the
# stub invented, and a call with no -o is refused rather than answered on
# stdout: every caller in this tree reads the status, which needs the body in a
# file.
curlstub() {  # -> a bin directory holding the stub
    local d
    d=$(mktemp -d "$TMP/curlstub.XXXXXX")
    cat > "$d/curl" <<'CURLEOF'
#!/usr/bin/env bash
d=$(dirname "$0"); out=""; wfmt=""
printf '%s\n' "$*" >> "$d/argv"
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -w) wfmt="$2"; shift ;;
    esac
    shift
done
tok=$(sed -n 's/^header = "Authorization: Bearer \(.*\)"$/\1/p')
[ -n "$tok" ] || exit 2
: > "$d/asked.$tok"
[ -n "$out" ] || { echo "curl stub: called with no -o FILE" >&2; exit 2; }
code=200
[ -f "$d/status.$tok" ] && code=$(cat "$d/status.$tok")
emit_code() { case "$wfmt" in *'%{http_code}'*) printf '%s' "$code" ;; esac; }
if [ "$code" = 000 ]; then emit_code; exit 7; fi
if [ -f "$d/body.$tok" ]; then cat "$d/body.$tok" > "$out"; else : > "$out"; fi
emit_code
exit 0
CURLEOF
    chmod +x "$d/curl"
    printf '%s\n' "$d"
}

echo "--- case 2: the seven lifecycle modes append one row each ---"

if ! have jq; then
    skip "case 2: lifecycle rows" "no jq"
else
    W2=$(world)
    for pair in "--turn-end e" "--turn-fail f" "--session-end x" \
                "--subagent-start a" "--subagent-end z" "--compact-mark c" "--perm-mark p"; do
        m=${pair%% *}; ev=${pair##* }
        : > "$W2/data/turn-log.tsv"
        out=$(printf '{"session_id":"%s","prompt_id":"p1","agent_id":"ag1","reason":"clear","error_type":"rate_limit","agent_type":"explore","compaction_reason":"auto"}' "$UUID" \
              | sess "$W2" -- "$m" 2>/dev/null)
        rc=$?
        report 0  "$rc"  "case 2 [$m]: exits 0"
        report "" "$out" "case 2 [$m]: writes nothing to stdout"
        report 1 "$(grep -c . "$W2/data/turn-log.tsv")" "case 2 [$m]: appends exactly one row"
        report 6 "$(awk -F'\t' 'NR==1{print NF}' "$W2/data/turn-log.tsv")" "case 2 [$m]: the row has six columns"
        report "$ev" "$(awk -F'\t' 'NR==1{print $3}' "$W2/data/turn-log.tsv")" "case 2 [$m]: the row's event letter"
        report "$UUID" "$(awk -F'\t' 'NR==1{print $2}' "$W2/data/turn-log.tsv")" "case 2 [$m]: the row carries the payload's session id"
    done

    for bad in "" "not json at all" "{unbalanced"; do
        : > "$W2/data/turn-log.tsv"
        out=$(printf '%s' "$bad" | sess "$W2" -- --turn-end 2>/dev/null)
        rc=$?
        report 0  "$rc"  "case 2 [stdin='$bad']: exits 0"
        report "" "$out" "case 2 [stdin='$bad']: writes nothing to stdout"
        report 0 "$(grep -c . "$W2/data/turn-log.tsv")" "case 2 [stdin='$bad']: appends no row"
    done

    # The payload Claude Code documents for SessionEnd, field for field.
    : > "$W2/data/turn-log.tsv"
    printf '{"session_id":"%s","transcript_path":"/t.jsonl","cwd":"/w","hook_event_name":"SessionEnd","reason":"exit"}' "$UUID" \
        | sess "$W2" -- --session-end >/dev/null 2>&1
    report "x	exit" "$(awk -F'\t' 'NR==1{print $3 "\t" $5}' "$W2/data/turn-log.tsv")" \
        "case 2: the documented SessionEnd payload logs its reason as the detail"

    # A hostile detail: the row separator, the row terminator, and a whole forged
    # row. jq's @tsv escapes all three, so the log gains one row, not three.
    : > "$W2/data/turn-log.tsv"
    forged=$(printf 'rate_limit\tforged\n9999999999\tdeadbeef\ts\t-\t-\t-')
    jq -cn --arg s "$UUID" --arg e "$forged" '{session_id:$s, error_type:$e}' \
        | sess "$W2" -- --turn-fail >/dev/null 2>&1
    report 1 "$(grep -c . "$W2/data/turn-log.tsv")" \
        "case 2: a tab, a newline and a forged row inside error_type still append exactly one row"
    report 6 "$(awk -F'\t' 'NR==1{print NF}' "$W2/data/turn-log.tsv")" \
        "case 2: ... with six columns (the separators are escaped, not written)"
    report 0 "$(awk -F'\t' '$2=="deadbeef"' "$W2/data/turn-log.tsv" | grep -c . || true)" \
        "case 2: ... and the forged session id never becomes a row of its own"
    report yes "$(grep -q 'forged' "$W2/data/turn-log.tsv" && echo yes || echo no)" \
        "case 2: ... the hostile text survives inside the detail field, escaped"

    echo "--- case 3: no data root ---"
    NW=$(mktemp -d "$TMP/nw.XXXXXX"); mkdir -p "$NW/cfg"
    out=$(printf '{"session_id":"%s"}' "$UUID" | sess "$NW" -- --turn-end 2>/dev/null)
    rc=$?
    report 0  "$rc"  "case 3: a lifecycle mode with no data root exits 0"
    report "" "$out" "case 3: ... and writes nothing to stdout"
    report absent "$([ -e "$NW/data" ] && echo present || echo absent)" \
        "case 3: ... and creates nothing"
fi

echo "--- case 9: identity from the environment, and cross-session lookup ---"

if ! have jq; then
    skip "case 9: identity" "no jq"
else
    W9=$(world)
    report "$UUID" "$(sess "$W9" -- whoami --id)" "case 9: whoami --id is the environment's session id"
    printf '{"session_name":"Brief bias adjustment"}\n' > "$W9/data/sessions/$UUID.json"
    printf '{"session_name":"Port the session CLI"}\n'   > "$W9/data/sessions/$UUID2.json"
    report "Brief bias adjustment" "$(sess "$W9" -- name "$UUID")" \
        "case 9: session name resolves a full id off a usage snapshot"
    report "Port the session CLI" "$(sess "$W9" -- name "${UUID2%%-*}")" \
        "case 9: ... and an 8-char prefix too"
    report "$UUID" "$(sess "$W9" -- id 'bias adjust')" \
        "case 9: session id resolves a title substring, case-insensitively"
    report 1 "$( (sess "$W9" -- name 00000000 >/dev/null 2>&1); echo $? )" \
        "case 9: an id that matches nothing exits 1"

    # Every real invocation reaches the CLI through a symlink on PATH, which is
    # the whole reason the entry prologue walks symlinks at all — and nothing
    # exercised that until now.
    BINL=$(mktemp -d "$TMP/bindir.XXXXXX"); ln -sf "$BIN" "$BINL/session"
    report "$UUID" "$(env -i PATH="$BINL:$PATH" HOME="$FH" TZ=UTC \
        CLAUDE_CONFIG_DIR="$W9/cfg" SESSION_DATA_DIR="$W9/data" \
        CLAUDE_CODE_SESSION_ID="$UUID" timeout 30 session whoami --id 2>&1)" \
        "case 9: the CLI answers through a bindir symlink, which is how it is always reached"
fi

echo "--- case 10: guard, json and the missing-cache exits ---"

if ! have jq; then
    skip "case 10: guard/json" "no jq"
else
    W10=$(world)
    mklogin "$W10" me@example.com
    NOWI=$(date +%s)

    out=$(sess "$W10" -- --guard 2>&1); rc=$?
    report 1 "$rc" "case 10: --guard without a cache exits 1"

    mkcache "$W10" me@example.com 10 10 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    out=$(sess "$W10" FIVE_GUARD=50 WEEK_GUARD=off -- --guard); rc=$?
    report 0 "$rc" "case 10: --guard under the cap exits 0"
    report OK "$(printf '%s' "$out" | cut -d: -f1)" "case 10: ... and says OK"

    mkcache "$W10" me@example.com 99 10 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    out=$(sess "$W10" FIVE_GUARD=50 WEEK_GUARD=off -- --guard); rc=$?
    report 3 "$rc" "case 10: --guard over the cap exits 3"
    report PAUSE "$(printf '%s' "$out" | cut -d: -f1)" "case 10: ... and says PAUSE"

    out=$(sess "$W10" -- --json)
    report "me@example.com" "$(printf '%s' "$out" | jq -r '.account')" "case 10: --json names the login"
    report 99 "$(printf '%s' "$out" | jq -r '.rate_limits.five_hour.used_percentage')" \
        "case 10: --json carries the cache's rate_limits"
    report 42 "$(printf '%s' "$out" | jq -r '.context_pct')" "case 10: --json carries the context fill"

    W10b=$(world); mklogin "$W10b" me@example.com
    out=$( (sess "$W10b" >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 10: the overview without a cache exits 1"
    report yes "$(printf '%s' "$out" | grep -q 'no cache at' && echo yes || echo no)" \
        "case 10: ... naming the file it looked for"
    report yes "$(printf '%s' "$out" | grep -q "$W10b/data" && echo yes || echo no)" \
        "case 10: ... under the injected data root, not a built-in one"

    # --compact never errors: it is wired into a prompt hook.
    out=$(sess "$W10b" -- --compact); rc=$?
    report 0 "$rc" "case 10: --compact without a cache still exits 0"
    report yes "$(printf '%s' "$out" | grep -q 'Claude usage limits' && echo yes || echo no)" \
        "case 10: ... and still prints its self-identifying line"
fi

echo "--- case 14: account (vault, swap, and the macOS shape) ---"

if ! have jq; then
    skip "case 14: account" "no jq"
else
    # `account` prints a table: [live] # LOGIN 5H RESET WEEK RESET FABLE AGE.
    # nolive drops the live label so every row splits the same way; acol LOGIN N
    # then prints column N of that login's row, matched on the whole login so a
    # plan never matches its own seat's row.
    nolive() { printf '%s\n' "$out" | sed 's/^  live /       /'; }
    acol() { nolive | awk -v l="$1" -v n="$2" '$2 == l { print $n }'; }
    W14=$(world)
    V="$W14/vault"
    mklogin "$W14" a@example.com
    printf '{"claudeAiOauth":{"accessToken":"tok-a"},"mcpOAuth":{"granola":"keep-me"}}\n' > "$W14/cfg/.credentials.json"

    out=$(sess "$W14" SESSION_ACCOUNTS_DIR="$V" -- account save 2>&1); rc=$?
    report 0 "$rc" "case 14: account save exits 0 with a live login"
    report yes "$([ -s "$V/a@example.com.json" ] && echo yes || echo no)" \
        "case 14: ... and vaults it under SESSION_ACCOUNTS_DIR"
    report "tok-a" "$(jq -r '.claudeAiOauth.accessToken' "$V/a@example.com.json")" \
        "case 14: ... carrying that login's oauth block"
    report 700 "$(stat -c %a "$V" 2>/dev/null || stat -f %Lp "$V")" "case 14: the vault is mode 700"

    # A second login, then switch back to the first.
    mklogin "$W14" b@example.com
    printf '{"claudeAiOauth":{"accessToken":"tok-b"},"mcpOAuth":{"granola":"keep-me"}}\n' > "$W14/cfg/.credentials.json"
    sess "$W14" SESSION_ACCOUNTS_DIR="$V" -- account save >/dev/null 2>&1
    out=$(sess "$W14" SESSION_ACCOUNTS_DIR="$V" -- account use a@ 2>&1); rc=$?
    report 0 "$rc" "case 14: account use exits 0"
    report "tok-a" "$(jq -r '.claudeAiOauth.accessToken' "$W14/cfg/.credentials.json")" \
        "case 14: ... swapping claudeAiOauth to the named login"
    report "keep-me" "$(jq -r '.mcpOAuth.granola' "$W14/cfg/.credentials.json")" \
        "case 14: ... and leaving mcpOAuth (not account-scoped) alone"
    report "a@example.com" "$(jq -r '.oauthAccount.emailAddress' "$W14/cfg/.claude.json")" \
        "case 14: ... and moving the identity with it"

    # `list` reads each vaulted login's own cache — the path that needs a
    # portable mtime, since a vault entry's age is printed beside its limits.
    NOWI=$(date +%s)
    mkcache "$W14" a@example.com 12 34 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    out=$(sess "$W14" SESSION_ACCOUNTS_DIR="$V" -- account 2>&1); rc=$?
    report 0 "$rc" "case 14: account list exits 0"
    report yes "$(printf '%s' "$out" | grep -q 'a@example.com' && echo yes || echo no)" \
        "case 14: ... listing the vaulted login"
    report "12% 34% now" "$(acol a@example.com 3) $(acol a@example.com 5) $(acol a@example.com 8)" \
        "case 14: ... with that login's cached headroom in the 5H and WEEK columns, and its age (a portable stat)"

    # A cache whose payload carried no 5h window at all (the statusline skips
    # that segment when it happens) lists it as n/a, never as -1%.
    printf '{"rate_limits":{"seven_day":{"used_percentage":34,"resets_at":%s}},"context_window":{"used_percentage":42},"model":{"display_name":"Fable 5"},"version":"2.1.233"}\n' \
        $(( NOWI + 6000 )) > "$W14/data/last-status.b@example.com.json"
    out=$(sess "$W14" SESSION_ACCOUNTS_DIR="$V" -- account 2>&1)
    report "n/a ? 34%" "$(acol b@example.com 3) $(acol b@example.com 4) $(acol b@example.com 5)" \
        "case 14: a cache with no 5h window lists it as n/a beside the weekly it does carry"
    report no "$(printf '%s' "$out" | grep -qF -- '-1%' && echo yes || echo no)" \
        "case 14: ... and no -1% appears anywhere in the listing"

    # The macOS shape: credentials live in the Keychain, so there is no
    # .credentials.json to swap. Everything else must keep working.
    M14=$(world); MV="$M14/vault"
    mkdir -p "$MV"; cp "$V/a@example.com.json" "$MV/"
    mklogin "$M14" a@example.com
    NOWI=$(date +%s)
    mkcache "$M14" a@example.com 12 34 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    out=$( (sess "$M14" SESSION_ACCOUNTS_DIR="$MV" -- account use a@ >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [macOS shape]: account use refuses without .credentials.json"
    report yes "$(printf '%s' "$out" | grep -q 'Keychain' && echo yes || echo no)" \
        "case 14 [macOS shape]: ... naming the Keychain as the reason"
    out=$( (sess "$M14" SESSION_ACCOUNTS_DIR="$MV" -- account save >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [macOS shape]: account save exits 1"
    report yes "$(printf '%s' "$out" | grep -q 'nothing to save' && echo yes || echo no)" \
        "case 14 [macOS shape]: ... saying there is nothing to save"
    out=$(sess "$M14" SESSION_ACCOUNTS_DIR="$MV" -- account 2>&1); rc=$?
    report 0 "$rc" "case 14 [macOS shape]: account list still works"
    report yes "$(printf '%s' "$out" | grep -q 'a@example.com' && echo yes || echo no)" \
        "case 14 [macOS shape]: ... and still lists the vault"

    # One email, two organisations: a personal Max plan and a Team seat. Their
    # credentials and rate-limit windows are separate, so they are two logins —
    # the seat's name carries the organisation, the plan's stays the bare email
    # (2026-09-15: keyed by email, `/login` into the seat overwrote the plan).
    W14b=$(world); V2="$W14b/vault"
    mklogin "$W14b" me@example.com
    printf '{"claudeAiOauth":{"accessToken":"tok-max"},"mcpOAuth":{}}\n' > "$W14b/cfg/.credentials.json"
    sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account save >/dev/null 2>&1
    printf '{"oauthAccount":{"emailAddress":"me@example.com","organizationType":"claude_team","organizationName":"Example Org"}}\n' > "$W14b/cfg/.claude.json"
    printf '{"claudeAiOauth":{"accessToken":"tok-team"},"mcpOAuth":{}}\n' > "$W14b/cfg/.credentials.json"
    out=$(sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account save 2>&1); rc=$?
    report 0 "$rc" "case 14 [same email]: saving a Team seat on an already-vaulted email exits 0"
    report yes "$([ -s "$V2/me@example.com+example-org.json" ] && echo yes || echo no)" \
        "case 14 [same email]: ... under <email>+<org slug>"
    report "tok-max" "$(jq -r '.claudeAiOauth.accessToken' "$V2/me@example.com.json")" \
        "case 14 [same email]: ... leaving the Max plan's entry untouched"
    report "me@example.com me@example.com+example-org" \
        "$(jq -r '"\(.email) \(.login)"' "$V2/me@example.com+example-org.json")" \
        "case 14 [same email]: the seat's entry records both the email and its login name"
    out=$(sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account 2>&1)
    report 2 "$(printf '%s\n' "$out" | grep -c 'me@example.com' || true)" \
        "case 14 [same email]: list shows both logins"
    report "me@example.com+example-org" "$(printf '%s\n' "$out" | awk '$1 == "live" { print $3 }')" \
        "case 14 [same email]: ... marking the seat as live, in the first column"
    out=$( (sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account use me@example >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [same email]: a substring both names contain is ambiguous"
    report yes "$(printf '%s' "$out" | grep -q 'matches 2 logins' && echo yes || echo no)" \
        "case 14 [same email]: ... and says so"
    out=$(sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account use me@example.com 2>&1); rc=$?
    report 0 "$rc" "case 14 [same email]: the whole name selects the plan although it is a prefix of the seat's name"
    report "tok-max" "$(jq -r '.claudeAiOauth.accessToken' "$W14b/cfg/.credentials.json")" \
        "case 14 [same email]: ... swapping in the plan's credentials"
    report "" "$(jq -r '.oauthAccount.organizationType // empty' "$W14b/cfg/.claude.json")" \
        "case 14 [same email]: ... and the plan's identity"
    out=$(sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account use +EXAMPLE 2>&1); rc=$?
    report 0 "$rc" "case 14 [same email]: a substring only the seat's name has selects the seat, case-insensitively"
    report "tok-team" "$(jq -r '.claudeAiOauth.accessToken' "$W14b/cfg/.credentials.json")" \
        "case 14 [same email]: ... swapping in the seat's credentials"
    report "Example Org" "$(jq -r '.oauthAccount.organizationName' "$W14b/cfg/.claude.json")" \
        "case 14 [same email]: ... and its organisation"
    # The cache is keyed the same way, so the two logins' windows never mix.
    NOWI=$(date +%s)
    mkcache "$W14b" me@example.com+example-org 7 8 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    mkcache "$W14b" me@example.com 99 98 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    out=$(sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- --json)
    report "me@example.com+example-org 7" \
        "$(printf '%s' "$out" | jq -r '"\(.account) \(.rate_limits.five_hour.used_percentage)"')" \
        "case 14 [same email]: the live seat reads its own cache, not the plan's"
    out=$(sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account 2>&1)
    report "99% 7%" "$(acol me@example.com 3) $(acol me@example.com+example-org 3)" \
        "case 14 [same email]: ... and the list shows each login its own headroom"

    # Rows are numbered in name order, and a number is the shortest way to name
    # a login whose every substring is shared (the plan beside its own seat).
    report "1 me@example.com" "$(nolive | awk '$1=="1"{print $1, $2}')" \
        "case 14 [numbers]: the list is numbered in name order, the plan first"
    report "2 me@example.com+example-org" "$(nolive | awk '$1=="2"{print $1, $2}')" \
        "case 14 [numbers]: ... the seat second"
    out=$(sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account use 1 2>&1); rc=$?
    report 0 "$rc" "case 14 [numbers]: use 1 exits 0"
    report "tok-max" "$(jq -r '.claudeAiOauth.accessToken' "$W14b/cfg/.credentials.json")" \
        "case 14 [numbers]: ... selecting the plan by its row number"
    out=$( (sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account use 3 >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [numbers]: a number past the end exits 1"
    report yes "$(printf '%s' "$out" | grep -q 'no login numbered 3' && echo yes || echo no)" \
        "case 14 [numbers]: ... and says so"
    out=$( (sess "$W14b" SESSION_ACCOUNTS_DIR="$V2" -- account use 0 >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [numbers]: 0 is not a row"
fi

echo "--- case 14 [fable]: the Fable weekly cap, from the usage endpoint ---"

if ! have jq || ! have perl; then
    skip "case 14 [fable]" "needs jq and perl"
else
    # The statusline payload never carries Fable's cap, so `list` fetches it with
    # each vaulted login's own token, through the stub above.
    W14f=$(world); VF="$W14f/vault"; mkdir -p "$VF"
    FB=$(curlstub)
    NOWI=$(date +%s)
    vent() {  # LOGIN TOKEN EXPIRES_AT — a vault entry in the shape `account save` writes
        printf '{"email":"%s","login":"%s","oauthAccount":{"emailAddress":"%s"},"claudeAiOauth":{"accessToken":"%s","expiresAt":%s000}}\n' \
            "$1" "$1" "$1" "$2" "$3" > "$VF/$1.json"
    }
    fcache() {  # LOGIN PCT RESETS_AT AGE_S — a Fable cache, backdated by AGE_S
        printf '{"fable":{"used_percentage":%s,"resets_at":%s}}\n' "$2" "$3" > "$W14f/data/fable.$1.json"
        perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' $(( NOWI - $4 )) "$W14f/data/fable.$1.json"
    }
    vent f@example.com tok-f $(( NOWI + 3600 ))   # live, token good, the endpoint answers
    vent n@example.com tok-n $(( NOWI + 3600 ))   # token good, the endpoint refuses in-band
    vent x@example.com tok-x $(( NOWI - 60 ))     # token lapsed, a 2h-old fetch
    vent p@example.com tok-p $(( NOWI - 60 ))     # token lapsed, its fetch past the reset
    vent z@example.com tok-z $(( NOWI - 60 ))     # token lapsed, never fetched
    vent m@example.com tok-m $(( NOWI + 3600 ))   # token good, the response has no Fable row
    vent q@example.com tok-q $(( NOWI + 3600 ))   # token good, the Fable row has no percent
    mklogin "$W14f" f@example.com
    jq -c '{claudeAiOauth}' "$VF/f@example.com.json" > "$W14f/cfg/.credentials.json"
    # The live response's shape, trimmed: a weekly_all row beside the Fable one,
    # with the fractional seconds and +00:00 offset the server sends.
    printf '{"limits":[{"kind":"weekly_all","group":"weekly","percent":50,"resets_at":"2099-01-01T00:00:00.5+00:00","scope":null},{"kind":"weekly_scoped","group":"weekly","percent":83,"resets_at":"2099-01-01T00:00:00.123456+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}\n' \
        > "$FB/body.tok-f"
    printf '{"error":{"type":"rate_limit_error"}}\n' > "$FB/body.tok-n"
    printf '{"limits":[{"kind":"weekly_all","group":"weekly","percent":50,"resets_at":"2099-01-01T00:00:00.5+00:00","scope":null}]}\n' \
        > "$FB/body.tok-m"
    printf '{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":null,"resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}\n' \
        > "$FB/body.tok-q"
    fcache n@example.com 61 $(( NOWI + 3 * 86400 )) 0
    cp "$W14f/data/fable.n@example.com.json" "$TMP/fable-n.before"
    fcache m@example.com 55 $(( NOWI + 3 * 86400 )) 0
    cp "$W14f/data/fable.m@example.com.json" "$TMP/fable-m.before"
    fcache q@example.com 66 $(( NOWI + 3 * 86400 )) 0
    cp "$W14f/data/fable.q@example.com.json" "$TMP/fable-q.before"
    fcache x@example.com 40 $(( NOWI + 3 * 86400 )) 7200
    mkcache "$W14f" x@example.com 10 20 $(( NOWI + 600 )) $(( NOWI + 3 * 86400 ))
    fcache p@example.com 100 $(( NOWI - 3600 )) 90000

    out=$(sess "$W14f" PATH="$FB:$PATH" SESSION_ACCOUNTS_DIR="$VF" -- account 2>&1); rc=$?
    report 0 "$rc" "case 14 [fable]: account list exits 0"
    report "LOGIN 5H RESET WEEK RESET FABLE AGE" "$(printf '%s\n' "$out" | awk '$1 == "#" { print $2, $3, $4, $5, $6, $7, $8 }')" \
        "case 14 [fable]: the list is a table with a FABLE column and no Fable countdown (it resets with WEEK)"
    report "83% now" "$(acol f@example.com 7) $(acol f@example.com 8)" \
        "case 14 [fable]: a login with a live token lists the endpoint's Fable figure"
    report "- - - -" "$(acol f@example.com 3) $(acol f@example.com 4) $(acol f@example.com 5) $(acol f@example.com 6)" \
        "case 14 [fable]: ... with a dash in each 5H and WEEK column while it has no statusline cache"
    report '{"fable":{"used_percentage":83,"resets_at":4070908800}}' "$(cat "$W14f/data/fable.f@example.com.json" 2>&1)" \
        "case 14 [fable]: ... caching that row alone, its ISO reset as epoch seconds"
    report yes "$([ -s "$FB/argv" ] && echo yes || echo no)" "case 14 [fable]: curl was called"
    report 0 "$(grep -c 'tok-' "$FB/argv" || true)" \
        "case 14 [fable]: ... with the token on stdin, never in its argv"
    report no "$([ -e "$FB/asked.tok-x" ] || [ -e "$FB/asked.tok-p" ] || [ -e "$FB/asked.tok-z" ] && echo yes || echo no)" \
        "case 14 [fable]: a lapsed token is not sent at all (and so never refreshed)"
    report yes "$([ -e "$FB/asked.tok-n" ] && echo yes || echo no)" \
        "case 14 [fable]: a login whose token is good is fetched even when it already has a figure"
    report yes "$(cmp -s "$TMP/fable-n.before" "$W14f/data/fable.n@example.com.json" && echo yes || echo no)" \
        "case 14 [fable]: ... and an in-band refusal leaves that figure byte-identical"
    report "61% now" "$(acol n@example.com 7) $(acol n@example.com 8)" \
        "case 14 [fable]: ... and the list shows it"
    # A well-formed answer with no usable Fable row is not evidence the figure
    # went away: the endpoint is undocumented, so it keeps the last reading too.
    report yes "$([ -e "$FB/asked.tok-m" ] && cmp -s "$TMP/fable-m.before" "$W14f/data/fable.m@example.com.json" && echo yes || echo no)" \
        "case 14 [fable]: a response whose limits[] has no Fable row keeps the previous figure"
    report yes "$([ -e "$FB/asked.tok-q" ] && cmp -s "$TMP/fable-q.before" "$W14f/data/fable.q@example.com.json" && echo yes || echo no)" \
        "case 14 [fable]: ... and so does a Fable row with no percent"
    # AGE is the row's OLDEST figure: here a fresh statusline cache beside a
    # Fable fetch from two hours ago, so the row reads 2h, not now.
    report "10% 20% 40% 2h" "$(acol x@example.com 3) $(acol x@example.com 5) $(acol x@example.com 7) $(acol x@example.com 8)" \
        "case 14 [fable]: a lapsed token lists the last fetch, and AGE is the older of the row's two sources"
    report "~0% 1d" "$(acol p@example.com 7) $(acol p@example.com 8)" \
        "case 14 [fable]: ... and a fetch past its reset zeroes, like the weekly"
    report "n/a -" "$(acol z@example.com 7) $(acol z@example.com 8)" \
        "case 14 [fable]: a login never fetched lists n/a, and no age when there is no figure at all"
    report "" "$(cd "$W14f/data" && ls | grep '\.tmp\.')" \
        "case 14 [fable]: no temp file is left behind"

    # `use` swaps first and fetches after, so a refused or hung fetch never
    # stands between a capped session and the login that frees it.
    rm -f "$FB"/asked.*
    out=$(sess "$W14f" PATH="$FB:$PATH" SESSION_ACCOUNTS_DIR="$VF" -- account use n@ 2>&1); rc=$?
    report 0 "$rc" "case 14 [fable]: use exits 0 although the incoming login's fetch is refused"
    report "tok-n" "$(jq -r '.claudeAiOauth.accessToken' "$W14f/cfg/.credentials.json")" \
        "case 14 [fable]: ... having swapped the credentials"
    report yes "$([ -e "$FB/asked.tok-f" ] && echo yes || echo no)" \
        "case 14 [fable]: ... and refetched the outgoing login, whose figure freezes at the switch"
    report "61%" "$(acol n@example.com 7)" \
        "case 14 [fable]: ... printing the incoming login's row in the list's columns"
    report "n@example.com" "$(printf '%s\n' "$out" | awk '$1 == "live" { print $3 }')" \
        "case 14 [fable]: ... labelled live"

    out=$(sess "$W14f" PATH="$(minipath curl)" SESSION_ACCOUNTS_DIR="$VF" -- account 2>&1); rc=$?
    report 0 "$rc" "case 14 [fable]: with no curl on PATH the list still exits 0"
    report "83%" "$(acol f@example.com 7)" \
        "case 14 [fable]: ... listing each login's cached figure"
fi

echo "--- case 15: peers, reboot and resume ---"

if ! have jq; then
    skip "case 15: peers/reboot/resume" "no jq"
else
    W15=$(world)
    # A registry record for a pid that is genuinely alive (this suite's own), so
    # the liveness test passes without racing a spawned process.
    printf '{"pid":%d,"sessionId":"%s","name":"work-2a","status":"idle","tmux":"%%3","messagingSocketPath":"","kind":"interactive","cwd":"%s","updatedAt":2}\n' \
        "$$" "$UUID" "$TMP" > "$W15/cfg/sessions/$$.json"
    out=$(sess "$W15" -- peers --json); rc=$?
    report 0 "$rc" "case 15: peers --json exits 0"
    report "$UUID" "$(printf '%s' "$out" | jq -r '.[0].session_id')" "case 15: peers reports the registered session id"
    report "work-2a" "$(printf '%s' "$out" | jq -r '.[0].name')" "case 15: ... and its cross-session address"
    report "false" "$(printf '%s' "$out" | jq -r '.[0].reachable')" \
        "case 15: ... with REACH false when the messaging socket is missing"

    # A dead pid's leftover record is skipped, never deleted.
    printf '{"pid":2147480000,"sessionId":"%s","name":"ghost","status":"idle","tmux":"","messagingSocketPath":"","kind":"interactive","updatedAt":1}\n' \
        "$UUID2" > "$W15/cfg/sessions/2147480000.json"
    report 1 "$(sess "$W15" -- peers --json | jq -r 'length')" "case 15: a dead pid's record is skipped"
    report yes "$([ -e "$W15/cfg/sessions/2147480000.json" ] && echo yes || echo no)" \
        "case 15: ... and left on disk (the registry is Claude Code's)"

    NOTMUX=$(minipath tmux)
    # What needs tmux is opening the windows, so a real resume refuses; the dry
    # runs and -h touch no tmux and answer without it (see the S2 block).
    printf '%s\t%s\ttitle\n' "$UUID2" "$TMP" > "$W15/data/resume-queue.tsv"
    out=$( (sess "$W15" PATH="$NOTMUX" -- resume >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 15: a real resume without tmux refuses"
    report yes "$(printf '%s' "$out" | grep -q 'tmux' && echo yes || echo no)" \
        "case 15: ... naming tmux"
    rm -f "$W15/data/resume-queue.tsv"
    out=$( (sess "$W15" PATH="$NOTMUX" -- reboot -n >/dev/null) 2>&1 ); rc=$?
    report 0 "$rc" "case 15: reboot --dry-run works without tmux — it writes a snapshot and nothing else"
    rm -f "$W15/data/resume-queue.tsv"
    # peers, by contrast, invokes no tmux at all — it reads the presence
    # registry and prints the pane id the registry recorded. A tmux guard here
    # would refuse a verb that works, so there is none and this pins that.
    out=$(sess "$W15" PATH="$NOTMUX" -- peers --json); rc=$?
    report 0 "$rc" "case 15: peers without tmux still works (it invokes no tmux)"
    report "$UUID" "$(printf '%s' "$out" | jq -r '.[0].session_id')" \
        "case 15: ... and still reports the registered session"

    # resume replays a queue through a recording tmux stub: one window per row.
    FT=$(mktemp -d "$TMP/ft.XXXXXX")
    cat > "$FT/tmux" <<FAKETMUX
#!/bin/sh
printf '%s\n' "\$*" >> "$FT/log"
case "\${1:-}" in
  list-clients) [ -s "$FT/clients" ] && cat "$FT/clients" ;;
esac
exit 0
FAKETMUX
    chmod +x "$FT/tmux"
    : > "$FT/log"
    D1=$(mktemp -d "$TMP/rd1.XXXXXX"); D2=$(mktemp -d "$TMP/rd2.XXXXXX")
    printf '%s\t%s\ttitle one\n%s\t%s\ttitle two\n' \
        "$UUID2" "$D1" 22222222-2222-2222-2222-222222222222 "$D2" > "$W15/data/resume-queue.tsv"
    out=$(sess "$W15" PATH="$FT:$PATH" -- resume -n); rc=$?
    report 0 "$rc" "case 15: resume --dry-run exits 0"
    report 2 "$(printf '%s' "$out" | grep -c 'would reopen' || true)" "case 15: ... listing both queued sessions"
    report yes "$([ -s "$W15/data/resume-queue.tsv" ] && echo yes || echo no)" \
        "case 15: ... and leaving the queue alone"
    : > "$FT/log"
    out=$(sess "$W15" PATH="$FT:$PATH" -- resume); rc=$?
    report 0 "$rc" "case 15: resume exits 0"
    report 2 "$(grep -c '^new-window' "$FT/log" || true)" "case 15: ... opening one tmux window per queued row"
    report absent "$([ -e "$W15/data/resume-queue.tsv" ] && echo present || echo absent)" \
        "case 15: ... and consuming the queue once every row reopened"
    out=$( (sess "$W15" PATH="$FT:$PATH" -- resume >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 15: resume with nothing queued exits 1"
fi

echo "--- case 16: --focus-mark ---"

if ! have jq; then
    skip "case 16: focus-mark" "no jq"
else
    W16=$(world)
    FT16=$(mktemp -d "$TMP/ft16.XXXXXX")
    cat > "$FT16/tmux" <<FAKETMUX16
#!/bin/sh
printf '%s\n' "\$*" >> "$FT16/log"
case "\${1:-}" in
  list-clients)
    # tmux answers the format it is given; so does this. flog_row asks for
    # session+pane, the switch handler for a focused client's name, the tick
    # for name+session+pane+activity.
    case "\$*" in
      *client_activity*) f="$FT16/clients_tick" ;;
      *client_session*)  f="$FT16/clients_pane" ;;
      *)                 f="$FT16/clients_name" ;;
    esac
    [ -s "\$f" ] && cat "\$f"
    ;;
esac
exit 0
FAKETMUX16
    chmod +x "$FT16/tmux"
    : > "$FT16/log"
    : > "$FT16/clients_name"; : > "$FT16/clients_tick"
    printf 'vsc-worktree\t%%14\n' > "$FT16/clients_pane"
    printf '%s\n' "$UUID" > "$W16/data/panes/14"

    sess "$W16" PATH="$FT16:$PATH" -- --focus-mark in pts/9 >/dev/null 2>&1
    rc=$?
    report 0 "$rc" "case 16 [in]: exits 0"
    report 1 "$(grep -c . "$W16/data/focus-log.tsv")" "case 16 [in]: appends one focus row"
    report "in	pts/9	vsc-worktree	%14	$UUID" \
        "$(awk -F'\t' 'NR==1{print $2 "\t" $3 "\t" $4 "\t" $5 "\t" $6}' "$W16/data/focus-log.tsv")" \
        "case 16 [in]: the row carries event, client, tmux session, pane and the pane map's session id"
    report yes "$(awk -F'\t' 'NR==1{print $1}' "$W16/data/focus-log.tsv" | grep -qE '^[0-9]{10}\.[0-9]{3}$' && echo yes || echo no)" \
        "case 16 [in]: stamped with millisecond precision"

    : > "$W16/data/focus-log.tsv"
    sess "$W16" PATH="$FT16:$PATH" -- --focus-mark out pts/9 >/dev/null 2>&1
    report "out" "$(awk -F'\t' 'NR==1{print $2}' "$W16/data/focus-log.tsv")" "case 16 [out]: appends an out flank"

    # `switch` logs an "in" only for a client that is actually focused on that
    # tmux session; the stub is the list-clients filter's answer.
    : > "$W16/data/focus-log.tsv"
    printf 'pts/11\n' > "$FT16/clients_name"
    printf 'vsc-main\t%%14\n' > "$FT16/clients_pane"
    sess "$W16" PATH="$FT16:$PATH" -- --focus-mark switch vsc-main >/dev/null 2>&1
    report "in	pts/11	vsc-main" \
        "$(awk -F'\t' 'NR==1{print $2 "\t" $3 "\t" $4}' "$W16/data/focus-log.tsv")" \
        "case 16 [switch]: a focused client's switch logs an in on that tmux session"
    : > "$W16/data/focus-log.tsv"
    : > "$FT16/clients_name"
    sess "$W16" PATH="$FT16:$PATH" -- --focus-mark switch vsc-main >/dev/null 2>&1
    report 0 "$(grep -c . "$W16/data/focus-log.tsv" || true)" \
        "case 16 [switch]: no focused client on that session logs nothing"

    # `tick` (cron, 1/min): one act row per client with input in the last 90 s,
    # stamped with the ACTUAL input time rather than tick time.
    : > "$W16/data/focus-log.tsv"
    NOWI=$(date +%s)
    RECENT=$(( NOWI - 10 )); STALE=$(( NOWI - 200 ))
    printf 'pts/9\tvsc-a\t%%14\t%s\npts/12\tvsc-b\t%%15\t%s\n' "$RECENT" "$STALE" > "$FT16/clients_tick"
    sess "$W16" PATH="$FT16:$PATH" -- --focus-mark tick >/dev/null 2>&1
    report 1 "$(grep -c . "$W16/data/focus-log.tsv" || true)" \
        "case 16 [tick]: only the client with recent input gets a row"
    report "$RECENT	act	pts/9" \
        "$(awk -F'\t' 'NR==1{print $1 "\t" $2 "\t" $3}' "$W16/data/focus-log.tsv")" \
        "case 16 [tick]: stamped with client_activity, not tick time"

    # Without tmux the hook is a silent no-op: it is wired into a tmux hook and
    # a cron line, and neither can show an error to anyone.
    : > "$W16/data/focus-log.tsv"
    NOTMUX16=$(minipath tmux)
    out=$( (sess "$W16" PATH="$NOTMUX16" -- --focus-mark in pts/9 >/dev/null) 2>&1 ); rc=$?
    report 0 "$rc" "case 16: without tmux, --focus-mark exits 0"
    report "" "$out" "case 16: ... silently"
    report 0 "$(grep -c . "$W16/data/focus-log.tsv" || true)" "case 16: ... and logs nothing"

    # The millisecond stamp must not come from `date +%s.%3N`: BSD date has no
    # %N, prints it literally, and every "$1+0" comparison in the reader then
    # reads the row as timestamp 0.
    BSDD=$(mktemp -d "$TMP/bsdd.XXXXXX")
    cat > "$BSDD/date" <<BSDDATE
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
    *%N*) printf '%s.%%3N\n' "\$($(command -v date) +%s)"; exit 0 ;;
  esac
done
exec $(command -v date) "\$@"
BSDDATE
    chmod +x "$BSDD/date"
    : > "$W16/data/focus-log.tsv"
    printf 'vsc-worktree\t%%14\n' > "$FT16/clients_pane"
    sess "$W16" PATH="$BSDD:$FT16:$PATH" -- --focus-mark in pts/9 >/dev/null 2>&1
    report yes "$(awk -F'\t' 'NR==1{print $1}' "$W16/data/focus-log.tsv" | grep -qE '^[0-9]{10}\.[0-9]{3}$' && echo yes || echo no)" \
        "case 16: the millisecond stamp survives a date(1) without %N"
fi


# ── A fixed day, so every reader case is deterministic ───────────────────────
# DAY0 is an exact multiple of 86400, and the harness pins TZ=UTC, so it is that
# day's local midnight. SESSION_NOW puts "now" at noon on it.
DAY0=1787788800
NOON=$(( DAY0 + 43200 ))

echo "--- case 4: the turn-start row does not wait for a cache ---"

if ! have jq; then
    skip "case 4: turn start" "no jq"
else
    W4=$(world); mklogin "$W4" me@example.com
    HOOKIN=$(printf '{"session_id":"%s","prompt_id":"p9"}' "$UUID")
    out=$(printf '%s' "$HOOKIN" | sess "$W4" -- --hook 2>/dev/null); rc=$?
    report 0  "$rc"  "case 4: --hook without a cache exits 0"
    report "" "$out" "case 4: ... and injects nothing"
    report 1 "$(grep -c . "$W4/data/turn-log.tsv" 2>/dev/null || echo 0)" \
        "case 4: ... but still logs the turn START (the cache is the statusline's, not the hook's)"
    report "s	p9" "$(awk -F'\t' 'NR==1{print $3 "\t" $4}' "$W4/data/turn-log.tsv" 2>/dev/null || true)" \
        "case 4: ... as an s row carrying the prompt id"

    sleep 1
    printf '%s' "$HOOKIN" | sess "$W4" -- --turn-end >/dev/null 2>&1
    sleep 1   # the day end is `now`, and the comparison against it is strict
    j=$(sess "$W4" -- time --json 2>/dev/null)
    report 1 "$(printf '%s' "$j" | jq -r '.turns')" "case 4: the paired turn is counted"
    report yes "$(printf '%s' "$j" | jq -r 'if .active_s > 0 then "yes" else "no" end')" \
        "case 4: ... with active time, so a cacheless machine still tracks turns"

    # On a terminal the hook must not block on a stdin that will never arrive.
    if script -qec true /dev/null >/dev/null 2>&1; then
        W4b=$(world); mklogin "$W4b" me@example.com
        cat > "$TMP/ttyhook.sh" <<TTYEOF
#!/bin/sh
env -i PATH="\$PATH" HOME="$FH" TZ=UTC CLAUDE_CONFIG_DIR="$W4b/cfg" \\
    SESSION_DATA_DIR="$W4b/data" CLAUDE_CODE_SESSION_ID="$UUID" \\
    bash "$BIN" --hook
echo "rc=\$?" > "$W4b/rc"
TTYEOF
        chmod +x "$TMP/ttyhook.sh"
        timeout 10 script -qec "$TMP/ttyhook.sh" /dev/null >/dev/null 2>&1
        trc=$?
        report yes "$([ "$trc" != 124 ] && echo yes || echo no)" "case 4: --hook on a terminal returns rather than blocking on stdin"
        report "rc=0" "$(cat "$W4b/rc" 2>/dev/null)" "case 4: ... exiting 0"
        report 0 "$(grep -c . "$W4b/data/turn-log.tsv" 2>/dev/null || echo 0)" \
            "case 4: ... and logging no turn (there is no prompt behind it)"
    else
        skip "case 4: --hook on a terminal" "no script(1) with -qec"
    fi
fi

echo "--- case 5: the warn gate and the advisory's armed-waiter claim ---"

if ! have jq; then
    skip "case 5: warn gate" "no jq"
else
    W5=$(world); mklogin "$W5" me@example.com
    HOOKIN=$(printf '{"session_id":"%s","prompt_id":"p1"}' "$UUID")
    hook5() { printf '%s' "$HOOKIN" | sess "$W5" -- --hook 2>/dev/null; }
    NOWI=$(date +%s)

    mkcache "$W5" me@example.com 10 10 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    report "" "$(hook5)" "case 5: below the threshold the hook injects nothing at all"

    mkcache "$W5" me@example.com 90 10 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    out=$(hook5)
    report "true" "$(printf '%s' "$out" | jq -r '.suppressOutput')" \
        "case 5: at the threshold it emits one hook object with suppressOutput"
    report "UserPromptSubmit" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" \
        "case 5: ... naming the event"
    ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')
    report yes "$(printf '%s' "$ctx" | grep -q '5h rate limit at 90%' && echo yes || echo no)" \
        "case 5: ... and the advisory names the window that crossed"
    report yes "$(printf '%s' "$ctx" | grep -q 'FIRST launch' && echo yes || echo no)" \
        "case 5: with no rewake entry wired, the advisory tells the model to launch the wait itself"

    # The armed-waiter sentence is a promise: claim it only when an entry that
    # the harness will actually background is present. grep cannot tell.
    armed='{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash /x/session/session --rewake-waiter","asyncRewake":true,"timeout":700000}]}]}}'
    printf '%s\n' "$armed" > "$W5/cfg/settings.json"
    ctx=$(hook5 | jq -r '.hookSpecificOutput.additionalContext')
    report yes "$(printf '%s' "$ctx" | grep -q 'auto-resume waiter is already armed' && echo yes || echo no)" \
        "case 5: a real asyncRewake entry earns the armed-waiter sentence"

    for bad in \
        '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash /x/session/session --rewake-waiter","timeout":700000}]}]}}' \
        '{"hooks":{"UserPromptSubmit":[{"hooks":[{"type":"command","command":"bash /x/session/session --rewake-waiter","asyncRewake":false}]}]}}' \
        '{"env":{"NOTE":"the rewake-waiter is not installed here"}}' \
        '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo rewake-waiter"}]}]}}' ; do
        printf '%s\n' "$bad" > "$W5/cfg/settings.json"
        ctx=$(hook5 | jq -r '.hookSpecificOutput.additionalContext')
        report yes "$(printf '%s' "$ctx" | grep -q 'FIRST launch' && echo yes || echo no)" \
            "case 5: a settings.json that only greps for rewake-waiter gets the fallback text"
        report no "$(printf '%s' "$ctx" | grep -q 'already armed' && echo yes || echo no)" \
            "case 5: ... and never the armed-waiter promise"
    done
    rm -f "$W5/cfg/settings.json"
fi

echo "--- case 6: the time --json contract ---"

if ! have jq; then
    skip "case 6: time --json" "no jq"
else
    W6=$(world)
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3660 )) "$UUID" > "$W6/data/turn-log.tsv"
    j=$(sess "$W6" SESSION_NOW=$NOON -- time --json); rc=$?
    report 0 "$rc" "case 6: time --json exits 0"
    report "string" "$(printf '%s' "$j" | jq -r '.date|type')" "case 6: date is a string"
    report "$(fmt_epoch "$DAY0" %F)" "$(printf '%s' "$j" | jq -r '.date')" "case 6: ... the day being reported"
    for k in active_s attended_s watched_s turns longest_s unclosed open_turn_s failed prompts subagents waits_s ended; do
        report "yes" "$(printf '%s' "$j" | jq -r --arg k "$k" 'if (.[$k]|type=="number") and ((.[$k]|floor) == .[$k]) then "yes" else "no" end')" \
            "case 6: $k is an integer"
    done
    report yes "$(printf '%s' "$j" | jq -r 'if (.attended_basis | test("^(focus|active)$")) then "yes" else "no" end')" \
        "case 6: attended_basis is focus or active"

    # No focus log at all: attended is the active time, labelled as such, so a
    # consumer books an upper bound knowingly instead of reading a real zero.
    report "active" "$(printf '%s' "$j" | jq -r '.attended_basis')" "case 6: without a focus log the basis is active"
    report "$(printf '%s' "$j" | jq -r '.active_s')" "$(printf '%s' "$j" | jq -r '.attended_s')" \
        "case 6: ... and attended_s equals active_s"

    # A session with no rows of its own still gets a well-formed zero object.
    j0=$(sess "$W6" CLAUDE_CODE_SESSION_ID="$UUID2" SESSION_NOW=$NOON -- time --json); rc=$?
    report 0 "$rc" "case 6: a session with no rows still exits 0"
    report "0 0 0" "$(printf '%s' "$j0" | jq -r '[.turns,.active_s,.attended_s]|join(" ")')" \
        "case 6: ... with zeros, so a caller can always take the delta"
    report "$UUID2" "$(printf '%s' "$j0" | jq -r '.sid')" "case 6: ... under its own id"

    W6b=$(world)
    out=$( (sess "$W6b" SESSION_NOW=$NOON -- time --json >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 6: with no turn log at all, time exits 1"
    report yes "$(printf '%s' "$out" | grep -q 'no turn log yet' && echo yes || echo no)" "case 6: ... saying so"
fi

echo "--- case 7: span pairing, and the attended idle cap ---"

if ! have jq; then
    skip "case 7: spans" "no jq"
else
    W7=$(world)
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n%s\t%s\ts\tp2\t-\t-\n%s\t%s\te\tp2\t-\t-\n' \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3660 )) "$UUID" \
        $(( DAY0 + 7200 )) "$UUID" $(( DAY0 + 7500 )) "$UUID" > "$W7/data/turn-log.tsv"
    j=$(sess "$W7" SESSION_NOW=$NOON -- time --json)
    report 2   "$(printf '%s' "$j" | jq -r '.turns')"     "case 7: two closed turns"
    report 360 "$(printf '%s' "$j" | jq -r '.active_s')"  "case 7: active is the sum of the closed spans"
    report 300 "$(printf '%s' "$j" | jq -r '.longest_s')" "case 7: ... and the longest is the longest span"
    report 360 "$(printf '%s' "$j" | jq -r '.attended_s')" "case 7: with no focus log, attended falls back to active"

    # A focus span with one input in it. GRACE=5 means attention accrues for 5s
    # from the span's start and 5s from the act — not the whole 300s span.
    printf '%s.000\tin\tpts/9\tvsc-a\t%%14\t%s\n%s.000\tact\tpts/9\tvsc-a\t%%14\t%s\n%s.000\tout\tpts/9\tvsc-a\t%%14\t%s\n' \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3700 )) "$UUID" $(( DAY0 + 3900 )) "$UUID" \
        > "$W7/data/focus-log.tsv"
    j=$(sess "$W7" SESSION_NOW=$NOON SESSION_ATTEND_GRACE=5 -- time --json)
    report "focus" "$(printf '%s' "$j" | jq -r '.attended_basis')" "case 7: a focus log makes the basis focus"
    report 10 "$(printf '%s' "$j" | jq -r '.attended_s')" \
        "case 7: an idle gap longer than the grace is not attended (2 x 5s, not the 300s span)"
    j=$(sess "$W7" SESSION_NOW=$NOON SESSION_ATTEND_GRACE=600 -- time --json)
    report 300 "$(printf '%s' "$j" | jq -r '.attended_s')" \
        "case 7: a grace longer than the span attends the whole span"
    report 60 "$(printf '%s' "$j" | jq -r '.watched_s')" \
        "case 7: watched is the overlap of the turn spans and the focus span"
fi

echo "--- case 8: the archive floor ---"

if ! have jq; then
    skip "case 8: archive floor" "no jq"
else
    # Inside the floor the live file alone answers, so a poisoned archive row
    # dated inside the window must never be read.
    W8=$(world); mkdir -p "$W8/data/archive"
    printf '%s\t%s\ts\tp0\t-\t-\n%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( DAY0 - 2 * 86400 )) "$UUID" $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3660 )) "$UUID" \
        > "$W8/data/turn-log.tsv"
    printf '%s\t%s\ts\tpz\t-\t-\n%s\t%s\te\tpz\t-\t-\n' \
        $(( DAY0 + 7200 )) "$UUID" $(( DAY0 + 7800 )) "$UUID" > "$W8/data/archive/turn-log.tsv"
    j=$(sess "$W8" SESSION_NOW=$NOON -- time --json)
    report 60 "$(printf '%s' "$j" | jq -r '.active_s')" \
        "case 8: inside the floor the archive is not read (a poisoned in-window archive row is ignored)"

    # The proof that the floor is safe: it holds only while the live file
    # already covers the requested day. A live file whose FIRST row is newer
    # than the requested midnight does not, so the archive is read after all.
    W8b=$(world); mkdir -p "$W8b/data/archive"
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3660 )) "$UUID" > "$W8b/data/turn-log.tsv"
    printf '%s\t%s\ts\tpz\t-\t-\n%s\t%s\te\tpz\t-\t-\n' \
        $(( DAY0 + 7200 )) "$UUID" $(( DAY0 + 7800 )) "$UUID" > "$W8b/data/archive/turn-log.tsv"
    j=$(sess "$W8b" SESSION_NOW=$NOON -- time --json)
    report 660 "$(printf '%s' "$j" | jq -r '.active_s')" \
        "case 8: a live file that starts after the requested midnight makes the archive read anyway"

    # Far outside the floor, the archive is the only source — and the per-turn
    # tail has to come from the same pair of files as the totals.
    OLD=$(( DAY0 - 30 * 86400 ))
    W8c=$(world); mkdir -p "$W8c/data/archive"
    printf '%s\t%s\ts\tp1\t-\t-\n' $(( DAY0 + 3600 )) "$UUID" > "$W8c/data/turn-log.tsv"
    printf '%s\t%s\ts\tpo\t-\t-\n%s\t%s\te\tpo\t-\t-\n' \
        $(( OLD + 3600 )) "$UUID" $(( OLD + 3660 )) "$UUID" > "$W8c/data/archive/turn-log.tsv"
    out=$(sess "$W8c" SESSION_NOW=$NOON -- time --date "$(fmt_epoch "$OLD" %F)"); rc=$?
    report 0 "$rc" "case 8: --date 30 days back exits 0"
    report yes "$(printf '%s' "$out" | grep -q 'turns    1 closed' && echo yes || echo no)" \
        "case 8: ... reading the archive for a day past the retention horizon"
    report 1 "$(printf '%s' "$out" | grep -cE '^    [0-9][0-9]:[0-9][0-9]  ' || true)" \
        "case 8: ... and the per-turn tail comes from the archive too, not just the live file"
fi

echo "--- case 9 (continued): the ancestor walk ---"

if ! have jq; then
    skip "case 9: ancestor walk" "no jq"
elif [ ! -d /proc/self ]; then
    skip "case 9: ancestor walk" "no /proc on this host"
else
    W9b=$(world)
    # The var is in THIS shell's environment and removed from the grandchild's,
    # so the only way to answer is to walk up and read the ancestor's environ.
    cat > "$TMP/ancestor.sh" <<'ANCEOF'
# $1 = the session binary, $2 = the config dir, $3 = the data root.
# Deliberately not exec: this process has to stay alive as the parent, holding
# CLAUDE_CODE_SESSION_ID in its own environment.
env -u CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR="$2" SESSION_DATA_DIR="$3" \
    bash "$1" whoami --id
ANCEOF
    got=$(env -i PATH="$PATH" HOME="$FH" TZ=UTC CLAUDE_CODE_SESSION_ID="$UUID2" \
          bash "$TMP/ancestor.sh" "$BIN" "$W9b/cfg" "$W9b/data")
    report "$UUID2" "$got" "case 9: with the variable unset, the walk finds it in an ancestor's environment"
fi

echo "--- case 11 (continued): the CLI without GNU date ---"

if ! have jq; then
    skip "case 11: time without GNU date" "no jq"
elif ! have perl; then
    skip "case 11: time without GNU date" "no perl"
elif ! date -d @0 +%F >/dev/null 2>&1; then
    skip "case 11: time without GNU date" "this host has no GNU date to compare against"
else
    W11=$(world)
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n%s\t%s\ts\tp2\t-\t-\n%s\t%s\te\tp2\t-\t-\n' \
        $(( DAY0 - 86400 + 3600 )) "$UUID" $(( DAY0 - 86400 + 3900 )) "$UUID" \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3660 )) "$UUID" > "$W11/data/turn-log.tsv"
    # BSD date: -d is the DST flag, not a parser. The stub refuses it and passes
    # everything else through, which is exactly what a mac would do.
    BSD11=$(mktemp -d "$TMP/bsd11.XXXXXX")
    printf '#!/bin/sh\ncase "${1:-}" in -d) exit 1;; esac\nexec %s "$@"\n' "$(command -v date)" > "$BSD11/date"
    chmod +x "$BSD11/date"
    for args in "time" "time --yesterday" "time --date $(fmt_epoch $(( DAY0 - 86400 )) %F)"; do
        gnu=$(sess "$W11" SESSION_NOW=$NOON -- $args 2>&1)
        bsd=$(sess "$W11" SESSION_NOW=$NOON PATH="$BSD11:$PATH" -- $args 2>&1)
        report "$gnu" "$bsd" "case 11: \`session $args\` reads the same with and without GNU date"
        report yes "$(printf '%s' "$gnu" | grep -q 'session time' && echo yes || echo no)" \
            "case 11: ... and \`session $args\` actually produced a report (not two matching errors)"
    done
fi

# A host with no perl cannot resolve a day boundary at all, and an empty one
# reads as epoch 0 in every window filter — the whole log would be reported as
# today's work. It has to refuse instead.
if have jq; then
    WNP=$(world)
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3660 )) "$UUID" > "$WNP/data/turn-log.tsv"
    NOPERL=$(minipath perl)
    out=$( (sess "$WNP" PATH="$NOPERL" SESSION_NOW=$NOON -- time >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "case 11: without perl, session time refuses rather than reporting all of history as today"
    report yes "$(printf '%s' "$out" | grep -q 'day boundary' && echo yes || echo no)" \
        "case 11: ... naming the day boundary as what it could not resolve"
else
    skip "case 11: the no-perl refusal" "no jq"
fi

echo "--- case 17: the auto-resume waiter ---"

if ! have jq; then
    skip "case 17: rewake waiter" "no jq"
else
    W17=$(world); mklogin "$W17" me@example.com
    REW=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$UUID")

    # The waiter fails closed when it cannot find a claude ancestor, so a test
    # that expects it to ARM has to supply one. Running the CLI under a parent
    # whose argv[0] is `claude` is what production looks like; without this the
    # arming cases pass natively only because the suite itself runs inside a
    # Claude Code session, and fail in a container that has no such ancestor.
    cat > "$TMP/asclaude.sh" <<'ASCEOF'
# $1 = the session binary; the rest are its arguments. Reached as
#   bash -c 'exec -a claude bash "$@"' _ asclaude.sh <bin> <args...>
b=$1; shift
timeout 60 bash "$b" "$@"
ASCEOF
    claude_sess() {  # WORLD [VAR=VAL ...] -- <session args>
        local w=$1; shift
        local e=""
        while [ $# -gt 0 ] && [ "$1" != -- ]; do e="$e $1"; shift; done
        [ "${1:-}" = -- ] && shift
        env -i PATH="$PATH" HOME="$FH" TZ=UTC \
            CLAUDE_CONFIG_DIR="$w/cfg" SESSION_DATA_DIR="$w/data" \
            CLAUDE_CODE_SESSION_ID="$UUID" $e \
            bash -c 'exec -a claude bash "$@"' _ "$TMP/asclaude.sh" "$BIN" "$@"
    }
    NOWI=$(date +%s)

    mkcache "$W17" me@example.com 10 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))
    out=$(printf '%s' "$REW" | claude_sess "$W17" -- --rewake-waiter 2>&1); rc=$?
    report 0 "$rc" "case 17: below the threshold the waiter exits 0 at once"
    report absent "$([ -e "$W17/data/sessions/$UUID.rewaiter" ] && echo present || echo absent)" \
        "case 17: ... and arms nothing"

    # Warned, with a reset a couple of seconds out: the waiter arms, sleeps to
    # it and exits 2 — the exit code that IS the wake-up.
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 95 10 $(( NOWI + 6 )) $(( NOWI + 8 ))
    err=$( (printf '%s' "$REW" | claude_sess "$W17" -- --rewake-waiter >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "case 17: a warned window arms the waiter, which exits 2 at the reset"
    report yes "$(printf '%s' "$err" | grep -q 'reset to 0%' && echo yes || echo no)" \
        "case 17: ... with the wake-up text on stderr"
    report absent "$([ -e "$W17/data/sessions/$UUID.rewaiter" ] && echo present || echo absent)" \
        "case 17: ... and clears its pidfile on the way out"

    # One waiter per session: a second spawn that finds a live owner leaves.
    # The owner has to be a live process whose command line carries
    # `rewake-waiter`, which is fiddlier than it looks. `exec -a rewake-waiter
    # sleep 30` dies outside glibc — sleep dispatches on argv[0] and does not
    # know that program. And `bash -c "sleep 30"` under the rename execs sleep
    # straight away (bash's single-command optimisation), taking the new argv[0]
    # with it. A second command defeats the optimisation, so the renamed bash is
    # what stays alive. Verified in both legs before being relied on.
    bash -c "exec -a rewake-waiter bash -c 'sleep 30; :'" &
    OWNER=$!
    sleep 1
    printf '%s\n' "$OWNER" > "$W17/data/sessions/$UUID.rewaiter"
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 95 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))
    out=$(printf '%s' "$REW" | claude_sess "$W17" -- --rewake-waiter 2>&1); rc=$?
    report 0 "$rc" "case 17: a second spawn with a live owner exits 0"
    report "$OWNER" "$(cat "$W17/data/sessions/$UUID.rewaiter")" "case 17: ... leaving the owner's pidfile alone"
    kill "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null
    rm -f "$W17/data/sessions/$UUID.rewaiter"

    # StopFailure only arms on a usage cap.
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 10 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))
    out=$(printf '{"session_id":"%s","hook_event_name":"StopFailure","error_type":"api_error"}' "$UUID" \
          | claude_sess "$W17" -- --rewake-waiter 2>&1); rc=$?
    report 0 "$rc" "case 17: StopFailure on a non-cap error does not arm"
    # Both stamps are near, not just the 5h one: if the 5h reset slipped into
    # the past between minting and reading, the arming path falls back to the
    # weekly reset, and a stamp 10 hours out would sleep for 10 hours.
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 10 10 $(( NOWI + 6 )) $(( NOWI + 8 ))
    err=$( (printf '{"session_id":"%s","hook_event_name":"StopFailure","error_type":"rate_limit"}' "$UUID" \
          | claude_sess "$W17" -- --rewake-waiter >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "case 17: StopFailure on a usage cap arms even below the warn threshold"

    # The same shape with a Fable figure whose own window has already turned
    # over: it is not a reason to wait for anything, so the 5h reset a couple of
    # seconds out still decides. This is the real clock, where the wake-target
    # block's Fable cases run on a simulated one.
    printf '{"fable":{"used_percentage":99,"resets_at":%s}}\n' "$(( NOWI - 10 ))" \
        > "$W17/data/fable.me@example.com.json"
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 10 10 $(( NOWI + 6 )) $(( NOWI + 8 ))
    err=$( (printf '{"session_id":"%s","hook_event_name":"StopFailure","error_type":"rate_limit"}' "$UUID" \
          | claude_sess "$W17" -- --rewake-waiter >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "case 17: a Fable window that has already reset does not retarget the wait"
    report yes "$(printf '%s' "$err" | grep -q '5h rate-limit window has reset' && echo yes || echo no)" \
        "case 17: ... which still wakes on the 5h reset"
    rm -f "$W17/data/fable.me@example.com.json"

    # ── the parent walk, on the ps branch a mac would take ──────────────────
    # session_have_proc is the single platform decision point, so the branch is
    # forced by giving a COPY of the shipped tree a lib that answers no. The
    # code under test is the shipped file, byte for byte.
    PSTREE=$(mktemp -d "$TMP/pstree.XXXXXX")
    mkdir -p "$PSTREE/lib"
    cp "$BIN" "$PSTREE/session"
    cp "$SDIR"/lib/*.sh "$PSTREE/lib/"
    printf '\nsession_have_proc() { return 1; }\n' >> "$PSTREE/lib/common.sh"

    # fake ps: pid -> parent, pid -> command. The claude ancestor's `-p` sits in
    # a NON-first position, which is the whole reason proc_cmdline splits the
    # ps output into words instead of matching a substring.
    mkps() {  # mkps DIR "CMD_OF_1001" "CMD_OF_1002"
        cat > "$1/ps" <<PSEOF
#!/bin/sh
args="\$*"
pid=\${args##*-p }
case "\$args" in
  *ppid=*)
    case "\$pid" in 1001) echo 1002 ;; 1002) echo 1 ;; *) echo 1001 ;; esac ;;
  *command=*)
    case "\$pid" in
      1001) echo "$2" ;;
      1002) echo "$3" ;;
      *) echo "bash session --rewake-waiter" ;;
    esac ;;
esac
exit 0
PSEOF
        chmod +x "$1/ps"
    }
    psess() {  # psess WORLD PSDIR [VAR=VAL...] -- args
        local w=$1 d=$2; shift 2
        local e=""
        while [ $# -gt 0 ] && [ "$1" != -- ]; do e="$e $1"; shift; done
        [ "${1:-}" = -- ] && shift
        env -i PATH="$d:$PATH" HOME="$FH" TZ=UTC \
            CLAUDE_CONFIG_DIR="$w/cfg" SESSION_DATA_DIR="$w/data" \
            CLAUDE_CODE_SESSION_ID="$UUID" $e timeout 60 bash "$PSTREE/session" "$@"
    }

    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 95 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))
    PSD=$(mktemp -d "$TMP/psd.XXXXXX")

    mkps "$PSD" "claude --model sonnet -p" "bash -l"
    out=$(printf '%s' "$REW" | psess "$W17" "$PSD" -- --rewake-waiter 2>&1); rc=$?
    report 0 "$rc" "case 17 [ps branch]: a \`claude -p\` parent disarms the waiter"
    report absent "$([ -e "$W17/data/sessions/$UUID.rewaiter" ] && echo present || echo absent)" \
        "case 17 [ps branch]: ... arming nothing"

    # The nearest claude ancestor decides. Without the break the walk would
    # reach an outer `claude -p` (or any ssh -p) and silently never arm.
    mkps "$PSD" "claude --model sonnet" "claude -p outer"
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 95 10 $(( NOWI + 6 )) $(( NOWI + 8 ))
    err=$( (printf '%s' "$REW" | psess "$W17" "$PSD" -- --rewake-waiter >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "case 17 [ps branch]: an interactive claude parent arms, whatever sits above it"
    rm -f "$W17/data/sessions/$UUID.rewaiter"

    # Degraded process inspection must fail closed: never arm a waiter whose
    # parent could not be identified.
    mkps "$PSD" "bash -p something" "init"
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 95 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))
    out=$(printf '%s' "$REW" | psess "$W17" "$PSD" -- --rewake-waiter 2>&1); rc=$?
    report 0 "$rc" "case 17 [ps branch]: no claude ancestor at all fails closed"
    report absent "$([ -e "$W17/data/sessions/$UUID.rewaiter" ] && echo present || echo absent)" \
        "case 17 [ps branch]: ... arming nothing"

    # A login switch mid-wait is the wake-up, not the reset.
    if have inotifywait; then
        W17b=$(world); mklogin "$W17b" me@example.com
        NOWI=$(date +%s)
        mkcache "$W17b" me@example.com 95 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))
        ( printf '%s' "$REW" | claude_sess "$W17b" -- --rewake-waiter >/dev/null 2>"$W17b/err"; echo $? > "$W17b/rc" ) &
        WPID=$!
        i=0
        while [ ! -e "$W17b/data/sessions/$UUID.rewaiter" ] && [ "$i" -lt 15 ]; do sleep 1; i=$(( i + 1 )); done
        report present "$([ -e "$W17b/data/sessions/$UUID.rewaiter" ] && echo present || echo absent)" \
            "case 17: a distant reset leaves the waiter armed and sleeping"
        mklogin "$W17b" other@example.com
        i=0
        while [ ! -e "$W17b/rc" ] && [ "$i" -lt 25 ]; do sleep 1; i=$(( i + 1 )); done
        wait "$WPID" 2>/dev/null
        report 2 "$(cat "$W17b/rc" 2>/dev/null)" "case 17: a login switch mid-wait exits 2"
        report yes "$(grep -q 'login switched' "$W17b/err" && echo yes || echo no)" \
            "case 17: ... saying the switch is what woke it"
        report yes "$(grep -q 'earlier cap no longer applies' "$W17b/err" && echo yes || echo no)" \
            "case 17: ... and, with no audit row describing a landing tier, saying what it always said"
    else
        skip "case 17: login switch mid-wait" "no inotifywait (the poll fallback would take 15s a turn)"
    fi
fi

echo "--- case 18: the promoted title is bounded ---"

if ! have jq; then
    skip "case 18: title promotion" "no jq"
else
    W18=$(world); mklogin "$W18" me@example.com
    NOWI=$(date +%s)
    mkcache "$W18" me@example.com 10 10 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    mkdir -p "$W18/cfg/projects/-w-x"
    LONG=$(awk 'BEGIN{ s=""; for (i=0;i<300;i++) s = s "x"; print s }')
    jq -cn --arg t "$(printf 'Bad\001title\002here %s' "$LONG")" \
        '{type:"ai-title", aiTitle:$t}' > "$W18/cfg/projects/-w-x/$UUID.jsonl"
    printf '{"pid":%d,"sessionId":"%s","name":"w-x","nameSource":"derived","kind":"interactive","updatedAt":1}\n' \
        "$$" "$UUID" > "$W18/cfg/sessions/$$.json"
    out=$(printf '{"session_id":"%s","prompt_id":"p1"}' "$UUID" | sess "$W18" -- --hook 2>/dev/null)
    t=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.sessionTitle // ""')
    report 80 "$(printf '%s' "$t" | wc -c | tr -d ' ')" "case 18: a 300-character title is promoted at 80 characters"
    report no "$(printf '%s' "$t" | grep -q '[[:cntrl:]]' && echo yes || echo no)" \
        "case 18: ... with the control characters stripped"
    report yes "$(printf '%s' "$t" | grep -q '^Badtitlehere ' && echo yes || echo no)" \
        "case 18: ... and the readable text kept"

    # A session whose name the user already set is never overwritten.
    printf '{"pid":%d,"sessionId":"%s","name":"chosen","kind":"interactive","updatedAt":1}\n' \
        "$$" "$UUID" > "$W18/cfg/sessions/$$.json"
    out=$(printf '{"session_id":"%s","prompt_id":"p1"}' "$UUID" | sess "$W18" -- --hook 2>/dev/null)
    report "" "$out" "case 18: a session with a named source is left alone (no envelope at all)"
fi

echo "--- case 12 (continued): --session-end prunes once a day ---"

if ! have jq; then
    skip "case 12: --session-end prune" "no jq"
else
    W12=$(world)
    NOWI=$(date +%s)
    OLDR=$(( NOWI - 10 * 86400 )); NEWR=$(( NOWI - 3600 ))
    for lg in turn-log session-log focus-log; do
        printf '%s\tsid\told\n%s\tsid\tnew\n' "$OLDR" "$NEWR" > "$W12/data/$lg.tsv"
    done
    printf '{"session_id":"%s","reason":"exit"}' "$UUID" | sess "$W12" -- --session-end >/dev/null 2>&1
    report yes "$([ -e "$W12/data/.session-log-pruned" ] && echo yes || echo no)" \
        "case 12: --session-end prunes, so the logs stay bounded without the statusline"
    report "$OLDR	sid	old" "$(cat "$W12/data/archive/turn-log.tsv")" \
        "case 12: ... moving rows past the horizon into the archive"
    report yes "$(grep -q 'new' "$W12/data/turn-log.tsv" && echo yes || echo no)" \
        "case 12: ... and keeping the recent ones live"
    # The session-end row itself is still appended.
    report yes "$(awk -F'\t' '$3=="x"' "$W12/data/turn-log.tsv" | grep -q . && echo yes || echo no)" \
        "case 12: ... after logging its own session-end row"
fi


echo "--- case 19: session doctor ---"

if ! have jq; then
    skip "case 19: doctor" "no jq"
else
    B19=$(mktemp -d "$TMP/b19.XXXXXX"); ln -sf "$BIN" "$B19/session"
    CW=$(mktemp -d "$TMP/cw19.XXXXXX")          # a cwd carrying no project settings

    # doctor19 WORLD CWD [VAR=VAL ...] — the cwd matters: a project settings
    # file there overrides the user's statusLine, which is check 6's whole point.
    doctor19() {
        local w=$1 c=$2; shift 2
        local e=""
        while [ $# -gt 0 ]; do e="$e $1"; shift; done
        ( cd "$c" && env -i PATH="$B19:$PATH" HOME="$FH" TZ=UTC \
            CLAUDE_CONFIG_DIR="$w/cfg" SESSION_DATA_DIR="$w/data" \
            CLAUDE_CODE_SESSION_ID="$UUID" $e timeout 60 bash "$BIN" doctor 2>&1 )
    }
    dstate() {  # dstate OUTPUT LABEL -> the state on that check's line
        printf '%s' "$1" | awk -v l="$2" '
            { s=$1; $1=""; sub(/^ +/, "")
              if (index($0, l) == 1) { print s; exit } }'
    }

    # ── everything wired ─────────────────────────────────────────────────────
    W19=$(world); mklogin "$W19" me@example.com; chmod 700 "$W19/data"
    NOWI=$(date +%s)
    mkcache "$W19" me@example.com 10 10 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( NOWI - 300 )) "$UUID" $(( NOWI - 240 )) "$UUID" > "$W19/data/turn-log.tsv"
    jq -n --arg sl "bash $SDIR/statusline.sh" --arg rw "bash $SDIR/session --rewake-waiter" \
       '{statusLine: {type:"command", command:$sl, refreshInterval:10},
         hooks: {UserPromptSubmit: [{hooks: [{type:"command", command:$rw,
                                              asyncRewake:true, timeout:700000}]}]}}' \
       > "$W19/cfg/settings.json"

    out=$(doctor19 "$W19" "$CW"); rc=$?
    report 0 "$rc" "case 19 [wired]: exits 0"
    report 0 "$(printf '%s' "$out" | grep -c '^  FAIL' || true)" "case 19 [wired]: no FAIL lines"
    for lbl in 'data root' 'on PATH' 'cache' 'turn log' 'time --json' 'statusLine' 'session id' 'auto-resume' 'platform'; do
        report ok "$(dstate "$out" "$lbl")" "case 19 [wired]: $lbl"
    done
    report yes "$(printf '%s' "$out" | grep -q '2.1.233' && echo yes || echo no)" \
        "case 19 [wired]: the cache's Claude Code version is printed"
    report yes "$(printf '%s' "$out" | grep -q "$W19/data" && echo yes || echo no)" \
        "case 19 [wired]: the resolved data root is printed, so a wrong one is visible"

    # ── a fresh install: pending everywhere, and pending is not a failure ────
    W19b=$(mktemp -d "$TMP/w19b.XXXXXX"); mkdir -p "$W19b/cfg"
    out=$(doctor19 "$W19b" "$CW"); rc=$?
    report 0 "$rc" "case 19 [fresh]: exits 0 — pending is not a failure"
    report 0 "$(printf '%s' "$out" | grep -c '^  FAIL' || true)" "case 19 [fresh]: nothing is marked FAIL"
    for lbl in 'data root' 'cache' 'turn log' 'statusLine' 'auto-resume'; do
        report pending "$(dstate "$out" "$lbl")" "case 19 [fresh]: $lbl is pending"
    done

    # ── a project statusLine in the cwd silently wins, so the check has to
    #    read the EFFECTIVE one, not the user's ────────────────────────────────
    CW2=$(mktemp -d "$TMP/cw19b.XXXXXX"); mkdir -p "$CW2/.claude"
    printf '#!/bin/sh\necho other\n' > "$CW2/other-statusline.sh"; chmod +x "$CW2/other-statusline.sh"
    jq -n --arg sl "bash $CW2/other-statusline.sh" \
       '{statusLine: {type:"command", command:$sl}}' > "$CW2/.claude/settings.json"
    out=$(doctor19 "$W19" "$CW2"); rc=$?
    report 1 "$rc" "case 19 [foreign statusLine]: exits 1"
    report FAIL "$(dstate "$out" statusLine)" "case 19 [foreign statusLine]: the statusLine check fails"
    report yes "$(printf '%s' "$out" | grep -q "$CW2/.claude/settings.json" && echo yes || echo no)" \
        "case 19 [foreign statusLine]: naming the file that set it"

    # A statusLine of ours pointing at a file that is not there.
    CW3=$(mktemp -d "$TMP/cw19c.XXXXXX"); mkdir -p "$CW3/.claude"
    jq -n --arg sl "bash $CW3/gone/statusline.sh" '{statusLine: {type:"command", command:$sl}}' \
        > "$CW3/.claude/settings.json"
    out=$(doctor19 "$W19" "$CW3")
    report FAIL "$(dstate "$out" statusLine)" "case 19 [missing statusLine file]: fails"
    report yes "$(printf '%s' "$out" | grep -q 'does not exist' && echo yes || echo no)" \
        "case 19 [missing statusLine file]: saying so"

    # ── a cache frozen while a session is live: the statusline is not rendering
    W19c=$(world); mklogin "$W19c" me@example.com; chmod 700 "$W19c/data"
    NOWI=$(date +%s)
    mkcache "$W19c" me@example.com 10 10 $(( NOWI + 600 )) $(( NOWI + 6000 ))
    touch -t 202001010000 "$W19c/data/last-status.me@example.com.json"
    out=$(doctor19 "$W19c" "$CW"); rc=$?
    report 1 "$rc" "case 19 [frozen cache]: exits 1"
    report FAIL "$(dstate "$out" cache)" "case 19 [frozen cache]: the cache check fails inside a live session"
    # ... and the same cache with no session around it is not a failure.
    out=$(doctor19 "$W19c" "$CW" CLAUDE_CODE_SESSION_ID=)
    report ok "$(dstate "$out" cache)" "case 19 [frozen cache]: outside a session an old cache is fine"

    # ── a turn log of ends with no starts is exactly the defect this port fixed
    W19d=$(world); mklogin "$W19d" me@example.com; chmod 700 "$W19d/data"
    NOWI=$(date +%s)
    printf '%s\t%s\te\tp1\t-\t-\n' $(( NOWI - 240 )) "$UUID" > "$W19d/data/turn-log.tsv"
    out=$(doctor19 "$W19d" "$CW"); rc=$?
    report 1 "$rc" "case 19 [ends without starts]: exits 1"
    report FAIL "$(dstate "$out" 'turn log')" "case 19 [ends without starts]: the turn-log check fails"

    # ── a rewake entry without asyncRewake runs synchronously and blocks ─────
    W19e=$(world); mklogin "$W19e" me@example.com; chmod 700 "$W19e/data"
    jq -n --arg rw "bash $SDIR/session --rewake-waiter" \
       '{hooks: {UserPromptSubmit: [{hooks: [{type:"command", command:$rw, timeout:700000}]}]}}' \
       > "$W19e/cfg/settings.json"
    out=$(doctor19 "$W19e" "$CW"); rc=$?
    report 1 "$rc" "case 19 [malformed rewake]: exits 1"
    report FAIL "$(dstate "$out" auto-resume)" "case 19 [malformed rewake]: an entry without asyncRewake is a failure, not an absence"

    # ── a `time --json` that breaks the contract a task logger reads ─────────
    BAD19=$(mktemp -d "$TMP/bad19.XXXXXX"); mkdir -p "$BAD19/lib"
    sed 's/"attended_s":%d/"attended_s":"%d"/' "$BIN" > "$BAD19/session"; chmod +x "$BAD19/session"
    cp "$SDIR"/lib/*.sh "$BAD19/lib/"
    out=$( cd "$CW" && env -i PATH="$B19:$PATH" HOME="$FH" TZ=UTC \
            CLAUDE_CONFIG_DIR="$W19/cfg" SESSION_DATA_DIR="$W19/data" \
            CLAUDE_CODE_SESSION_ID="$UUID" timeout 60 bash "$BAD19/session" doctor 2>&1 )
    rc=$?
    report 1 "$rc" "case 19 [broken time --json]: exits 1"
    report FAIL "$(dstate "$out" 'time --json')" \
        "case 19 [broken time --json]: a string where the contract says an integer is caught by running it"

    # ── the data root's mode is part of being wired: it holds login-keyed data
    W19f=$(world); mklogin "$W19f" me@example.com; chmod 755 "$W19f/data"
    out=$(doctor19 "$W19f" "$CW"); rc=$?
    report 1 "$rc" "case 19 [world-readable root]: exits 1"
    report FAIL "$(dstate "$out" 'data root')" "case 19 [world-readable root]: mode 755 is a failure"

    # ── two copies of the CLI on one machine ────────────────────────────────
    OTHER=$(mktemp -d "$TMP/other19.XXXXXX"); ln -sf /bin/cat "$OTHER/session"
    out=$(doctor19 "$W19" "$CW" PATH="$OTHER:$PATH"); rc=$?
    report 1 "$rc" "case 19 [foreign session on PATH]: exits 1"
    report FAIL "$(dstate "$out" 'on PATH')" "case 19 [foreign session on PATH]: a different copy is a failure"

    report 2 "$( (doctor19 "$W19" "$CW" >/dev/null; true); (cd "$CW" && env -i PATH="$B19:$PATH" HOME="$FH" \
        CLAUDE_CONFIG_DIR="$W19/cfg" SESSION_DATA_DIR="$W19/data" bash "$BIN" doctor --all >/dev/null 2>&1); echo $? )" \
        "case 19: doctor takes no arguments"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# Review round. Each case below reproduces a defect a reviewer found and names
# what the wrong answer looked like, because every one of them was silent: the
# CLI kept exit 0 and printed a plausible number.
# ═══════════════════════════════════════════════════════════════════════════════

echo "--- F1: --date yesterday is one day, not two ---"

if ! have jq; then
    skip "F1: --date yesterday" "no jq"
else
    WF1=$(world)
    # One closed hour yesterday, ten closed minutes today.
    printf '%s\t%s\ts\ty1\t-\t-\n%s\t%s\te\ty1\t-\t-\n%s\t%s\ts\tt1\t-\t-\n%s\t%s\te\tt1\t-\t-\n' \
        $(( DAY0 - 86400 + 3600 )) "$UUID" $(( DAY0 - 86400 + 7200 )) "$UUID" \
        $(( DAY0 + 3600 ))         "$UUID" $(( DAY0 + 4200 ))         "$UUID" \
        > "$WF1/data/turn-log.tsv"

    flag=$(sess "$WF1" SESSION_NOW=$NOON -- time --yesterday --json)
    word=$(sess "$WF1" SESSION_NOW=$NOON -- time --date yesterday --json)
    dated=$(sess "$WF1" SESSION_NOW=$NOON -- time --date "$(fmt_epoch $(( DAY0 - 86400 )) %F)" --json)

    report "$flag" "$word" "F1: \`--date yesterday\` and \`--yesterday\` report the same day, byte for byte"
    report 3600 "$(printf '%s' "$word" | jq -r '.active_s')" \
        "F1: ... one day's active time, not two days' (the +1 day was free-texting to now)"
    report 1 "$(printf '%s' "$word" | jq -r '.turns')" "F1: ... and one day's turns"
    # The control that says the window itself was always right for a spelled-out
    # date — only the relative word built a two-day window.
    report "$flag" "$dated" "F1: a spelled-out date agrees with the flag too (the control)"

    # The label the JSON carries has to name the day it actually reported.
    report yesterday "$(printf '%s' "$word" | jq -r '.day')" "F1: the day field names yesterday"
    report "$(fmt_epoch $(( DAY0 - 30 * 86400 )) %F)" \
        "$(sess "$WF1" SESSION_NOW=$NOON -- time --date "$(fmt_epoch $(( DAY0 - 30 * 86400 )) %F)" --json | jq -r '.day')" \
        "F1: ... and a distant day names itself rather than \"today\""
fi

echo "--- F2: the attended basis follows the data that was read ---"

if ! have jq; then
    skip "F2: attended basis" "no jq"
else
    OLDD=$(( DAY0 - 30 * 86400 ))
    WF2=$(world); mkdir -p "$WF2/data/archive"
    # The day being audited is past the retention horizon, so both halves are
    # read; the live focus log is empty, which is what a machine looks like
    # after focus tracking has been off for longer than the live window.
    printf '%s\t%s\ts\tp1\t-\t-\n' $(( DAY0 + 3600 )) "$UUID" > "$WF2/data/turn-log.tsv"
    printf '%s\t%s\ts\tpo\t-\t-\n%s\t%s\te\tpo\t-\t-\n' \
        $(( OLDD + 3600 )) "$UUID" $(( OLDD + 4200 )) "$UUID" > "$WF2/data/archive/turn-log.tsv"
    printf '%s.000\tin\tpts/9\tvsc-a\t%%14\t%s\n%s.000\tout\tpts/9\tvsc-a\t%%14\t%s\n' \
        $(( OLDD + 3600 )) "$UUID" $(( OLDD + 3700 )) "$UUID" > "$WF2/data/archive/focus-log.tsv"

    j=$(sess "$WF2" SESSION_NOW=$NOON -- time --date "$(fmt_epoch "$OLDD" %F)" --json)
    report focus "$(printf '%s' "$j" | jq -r '.attended_basis')" \
        "F2: focus rows in the archive are a focus measurement, whatever the live file holds"
    report 100 "$(printf '%s' "$j" | jq -r '.attended_s')" \
        "F2: ... and the measured figure is the one reported (not the active time)"
    report 100 "$(printf '%s' "$j" | jq -r '.watched_s')" \
        "F2: ... which watched_s, computed from the same spans, agrees with"
    # The same invocation's other two renderings already agreed; now all three do.
    report yes "$(sess "$WF2" SESSION_NOW=$NOON -- time --date "$(fmt_epoch "$OLDD" %F)" \
        | grep -q 'attended 1m40s' && echo yes || echo no)" \
        "F2: ... and the text view still says the same thing"

    # The other end of the trade: a focus log that exists but produced no spans
    # for the window is not a measurement, so the basis falls back to active.
    WF2b=$(world)
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 4200 )) "$UUID" > "$WF2b/data/turn-log.tsv"
    printf '%s.000\tin\tpts/9\tvsc-a\t%%14\t%s\n' $(( DAY0 - 5 * 86400 )) "$UUID" \
        > "$WF2b/data/focus-log.tsv"
    j=$(sess "$WF2b" SESSION_NOW=$NOON -- time --json)
    report active "$(printf '%s' "$j" | jq -r '.attended_basis')" \
        "F2: a focus log with nothing in the window is not a measurement — the basis is active"
    report "$(printf '%s' "$j" | jq -r '.active_s')" "$(printf '%s' "$j" | jq -r '.attended_s')" \
        "F2: ... and attended falls back to the active time"
fi

echo "--- F3: a focus row without a timestamp is never written, and never hides the archive ---"

if ! have jq; then
    skip "F3: timestamp-less focus row" "no jq"
else
    WF3=$(world)
    FT3=$(mktemp -d "$TMP/ft3.XXXXXX")
    cat > "$FT3/tmux" <<FAKETMUX3
#!/bin/sh
case "\${1:-}" in list-clients) printf 'vsc-a\t%%14\n' ;; esac
exit 0
FAKETMUX3
    chmod +x "$FT3/tmux"
    NOPERL3=$(minipath perl)
    # A host with tmux and without perl: epoch_ms is the only perl call on this
    # path, and a row stamped with nothing is worse than no row at all.
    out=$( (sess "$WF3" PATH="$FT3:$NOPERL3" -- --focus-mark in pts/9 >/dev/null) 2>&1 ); rc=$?
    report 0 "$rc" "F3: without perl, --focus-mark still exits 0 (it is a hook)"
    report 0 "$(grep -c . "$WF3/data/focus-log.tsv" 2>/dev/null || echo 0)" \
        "F3: ... and writes no row rather than a row with an empty timestamp"
    # Positive control: the same fixture with perl present does write one.
    sess "$WF3" PATH="$FT3:$PATH" -- --focus-mark in pts/9 >/dev/null 2>&1
    report 1 "$(grep -c . "$WF3/data/focus-log.tsv" 2>/dev/null || echo 0)" \
        "F3: ... while with perl the same call writes exactly one (the control)"

    # The second half: a first row whose timestamp reads as 0 must not license
    # the archive skip. printf %d of an empty field is 0, and 0 is older than
    # any midnight, so the live file would "provably" cover everything.
    WF3b=$(world); mkdir -p "$WF3b/data/archive"
    { printf '\n'
      printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
          $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3660 )) "$UUID"
    } > "$WF3b/data/turn-log.tsv"
    printf '%s\t%s\ts\tpz\t-\t-\n%s\t%s\te\tpz\t-\t-\n' \
        $(( DAY0 + 7200 )) "$UUID" $(( DAY0 + 7800 )) "$UUID" > "$WF3b/data/archive/turn-log.tsv"
    report 660 "$(sess "$WF3b" SESSION_NOW=$NOON -- time --json | jq -r '.active_s')" \
        "F3: a blank first line does not convince log_srcs that the live file covers the day"
fi

echo "--- F4: the doctor does not blame the turn log for someone else's failure ---"

if ! have jq; then
    skip "F4: doctor time --json wording" "no jq"
else
    WF4=$(world); mklogin "$WF4" me@example.com; chmod 700 "$WF4/data"
    NOWI=$(date +%s)
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( NOWI - 300 )) "$UUID" $(( NOWI - 240 )) "$UUID" > "$WF4/data/turn-log.tsv"
    NOPERL4=$(minipath perl)
    # `time --json` fails here because the day boundary needs perl — nothing to
    # do with the turn log, which has rows and which check 4 reports as ok.
    out=$(doctor19 "$WF4" "$CW" PATH="$NOPERL4:$B19")
    report FAIL "$(dstate "$out" 'time --json')" "F4: a failing time --json is a FAIL, not a pending"
    report no "$(printf '%s' "$out" | grep -q 'no turn log to report on' && echo yes || echo no)" \
        "F4: ... and the doctor does not claim there is no turn log over a populated one"
    report ok "$(dstate "$out" 'turn log')" "F4: ... which the turn-log check on the same run calls ok"
fi

echo "--- F5: a config file nothing can parse is a failure, not an absence ---"

if ! have jq; then
    skip "F5: unparseable config" "no jq"
else
    WF5=$(world); mklogin "$WF5" me@example.com; chmod 700 "$WF5/data"
    printf '{ this is not json\n' > "$WF5/cfg/settings.json"
    out=$(doctor19 "$WF5" "$CW"); rc=$?
    report 1 "$rc" "F5: a settings.json jq cannot parse exits 1"
    report FAIL "$(dstate "$out" settings)" "F5: ... reported as a FAIL on the settings line"
    report no "$(printf '%s' "$out" | grep -qE '^  pending +statusLine +none configured' && echo yes || echo no)" \
        "F5: ... and the statusLine check no longer reads as \"nothing configured yet\""
    report FAIL "$(dstate "$out" auto-resume)" "F5: ... nor auto-resume as \"off\""

    # The sibling misdiagnosis: an unreadable settings.json is not "invalid JSON"
    # (found by the installer suite's unreadable-settings case — the
    # doctor's line leaked into the install output and matched its grep).
    if [ "$(id -u)" = 0 ]; then
        skip "F5: an unreadable settings.json" "root reads mode-000 files"
    else
        WF5c=$(world); mklogin "$WF5c" me@example.com; chmod 700 "$WF5c/data"
        printf '{"model":"opus"}\n' > "$WF5c/cfg/settings.json"
        chmod 000 "$WF5c/cfg/settings.json"
        out=$(doctor19 "$WF5c" "$CW")
        chmod 600 "$WF5c/cfg/settings.json"
        report FAIL "$(dstate "$out" settings)" "F5: an unreadable settings.json is a FAIL"
        report no "$(grep -q 'not valid JSON' <<<"$out" && echo yes || echo no)" "F5: ... not diagnosed as invalid JSON"
        report yes "$(grep -qi 'cannot be read' <<<"$out" && echo yes || echo no)" "F5: ... but as unreadable"
        # The sibling check reading the same file: a settings.json that exists
        # and cannot be read is not one that has not been created yet.
        report FAIL "$(dstate "$out" auto-resume)" "F5: ... and the auto-resume check does not call it absent"
    fi

    # A session.conf that is not valid shell is the same class: the lib sources
    # it, and a syntax error there silently leaves every path at its default.
    WF5b=$(world); mklogin "$WF5b" me@example.com; chmod 700 "$WF5b/data"
    printf 'SESSION_DATA_DIR="${SESSION_DATA_DIR:-/x\n' > "$WF5b/cfg/session.conf"
    out=$(doctor19 "$WF5b" "$CW"); rc=$?
    report 1 "$rc" "F5: a session.conf that is not valid shell exits 1"
    report yes "$(printf '%s' "$out" | grep -qE '^  FAIL +session.conf' && echo yes || echo no)" \
        "F5: ... on its own line"
    # Control: a well-formed conf is not flagged.
    printf 'SESSION_DATA_DIR="${SESSION_DATA_DIR:-%s}"\n' "$WF5b/data" > "$WF5b/cfg/session.conf"
    out=$(doctor19 "$WF5b" "$CW")
    report no "$(printf '%s' "$out" | grep -qE '^  FAIL +session.conf' && echo yes || echo no)" \
        "F5: ... and a well-formed one is not (the control)"
fi

echo "--- doctor conf line: the doctor can say that session.conf was ignored, not absent ---"

if ! have jq; then
    skip "doctor conf line: an untrusted session.conf" "no jq"
else
    # The lib skips a conf that is group- or world-writable and says so on the
    # stderr a statusline render discards, so the only symptom left was every
    # path silently on its default — with check 1 reporting "the default under
    # the config dir", which is the truth of that moment and indistinguishable
    # from "no conf exists". This is the one failure the conf gate creates, and
    # the doctor is the tool whose job is naming it. Mode, not permission
    # enforcement, so the case is real as root too.
    WW2=$(world); mklogin "$WW2" me@example.com; chmod 700 "$WW2/data"
    printf 'SESSION_DATA_DIR="${SESSION_DATA_DIR:-%s}"\n' "$WW2/data" > "$WW2/cfg/session.conf"
    chmod 664 "$WW2/cfg/session.conf"
    out=$(doctor19 "$WW2" "$CW"); rc=$?
    report 1 "$rc" "doctor conf line: a conf the lib skips exits 1"
    report FAIL "$(dstate "$out" 'session.conf')" "doctor conf line: ... on the session.conf line"
    report yes "$(grep -q 'mode 664' <<<"$out" && echo yes || echo no)" "doctor conf line: ... naming the mode"

    chmod 600 "$WW2/cfg/session.conf"
    out=$(doctor19 "$WW2" "$CW"); rc=$?
    report 0 "$rc" "doctor conf line: a 600 conf exits 0 (the control)"
    report no "$(grep -qE '^  FAIL +session.conf' <<<"$out" && echo yes || echo no)" \
        "doctor conf line: ... with no session.conf line at all"

    # An unreadable conf is the settings.json misdiagnosis in the other file:
    # `bash -n` cannot open it and reports it as bad shell, which sends the
    # reader to edit a file whose contents are fine.
    if [ "$(id -u)" = 0 ]; then
        skip "doctor conf line: an unreadable session.conf" "root reads mode-000 files"
    else
        chmod 000 "$WW2/cfg/session.conf"
        out=$(doctor19 "$WW2" "$CW"); rc=$?
        chmod 600 "$WW2/cfg/session.conf"
        report 1 "$rc" "doctor conf line: an unreadable conf exits 1"
        report FAIL "$(dstate "$out" 'session.conf')" "doctor conf line: ... on the session.conf line"
        report no "$(grep -q 'not valid shell' <<<"$out" && echo yes || echo no)" \
            "doctor conf line: ... without blaming contents nobody could read"
    fi
fi

echo "--- S6: hooks without a statusline is a supported install, not a fault ---"

if ! have jq; then
    skip "S6: hooks-only install" "no jq"
else
    WS6=$(world); mklogin "$WS6" me@example.com; chmod 700 "$WS6/data"
    NOWI=$(date +%s)
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( NOWI - 300 )) "$UUID" $(( NOWI - 240 )) "$UUID" > "$WS6/data/turn-log.tsv"
    out=$(doctor19 "$WS6" "$CW"); rc=$?
    report 0 "$rc" "S6: an install with the hooks and no statusline exits 0"
    report pending "$(dstate "$out" cache)" "S6: ... with the missing cache pending, not failing"

    # And the FAIL it is scoped to still fires: our statusLine is configured,
    # the rows are arriving, and no cache has appeared.
    jq -n --arg sl "bash $SDIR/statusline.sh" '{statusLine:{type:"command",command:$sl}}' \
        > "$WS6/cfg/settings.json"
    out=$(doctor19 "$WS6" "$CW"); rc=$?
    report 1 "$rc" "S6: with our statusLine configured and still no cache, that is a FAIL"
    report FAIL "$(dstate "$out" cache)" "S6: ... on the cache line"
fi

echo "--- F6: a large argv does not invert the waiter's ancestor checks ---"

if ! have jq; then
    skip "F6: large argv" "no jq"
else
    # Reproduced through the ps branch, where the fake ps can hand back an argv
    # of any size. Under pipefail, `proc_cmdline | head -1 | grep -q` takes
    # SIGPIPE once the write exceeds the pipe buffer (65536 here) and returns
    # 141 — which reads as "no claude ancestor", and the fail-closed rule then
    # never arms the waiter for the life of the session.
    BIGARG=$(awk 'BEGIN{ s=""; for (i=0;i<20000;i++) s = s "yyyyyyyyyy"; print s }')
    PSD6=$(mktemp -d "$TMP/psd6.XXXXXX")
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 95 10 $(( NOWI + 6 )) $(( NOWI + 8 ))
    mkps "$PSD6" "claude --model sonnet $BIGARG" "bash -l"
    err=$( (printf '%s' "$REW" | psess "$W17" "$PSD6" -- --rewake-waiter >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "F6: a claude ancestor with a 200 KB argv still arms the waiter"
    rm -f "$W17/data/sessions/$UUID.rewaiter"

    # The other direction, same mechanism: the -p check must not read as absent.
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 95 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))
    # -p near the head: grep -qx exits at its match, and only then does the
    # writer take SIGPIPE. With -p last, grep reads to EOF and the inversion
    # never happens — which is why the first fixture puts the blob after it.
    mkps "$PSD6" "claude -p --model sonnet $BIGARG" "bash -l"
    out=$(printf '%s' "$REW" | psess "$W17" "$PSD6" -- --rewake-waiter 2>&1); rc=$?
    report 0 "$rc" "F6: a \`claude -p\` parent with a 200 KB argv still disarms it"
    report absent "$([ -e "$W17/data/sessions/$UUID.rewaiter" ] && echo present || echo absent)" \
        "F6: ... arming nothing"

    # A -p that is only a substring of another argument is still not a -p.
    NOWI=$(date +%s)
    mkcache "$W17" me@example.com 95 10 $(( NOWI + 6 )) $(( NOWI + 8 ))
    mkps "$PSD6" "claude --model sonnet-p --resume x-p" "bash -l"
    err=$( (printf '%s' "$REW" | psess "$W17" "$PSD6" -- --rewake-waiter >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "F6: a -p inside another word does not disarm the waiter (the control)"
    rm -f "$W17/data/sessions/$UUID.rewaiter"
fi

echo "--- F7: resume --scan does not offer a transcript it could not stat ---"

if ! have jq; then
    skip "F7: scan ordering" "no jq"
else
    WF7=$(world)
    FT7=$(mktemp -d "$TMP/ft7.XXXXXX")
    printf '#!/bin/sh\nexit 0\n' > "$FT7/tmux"; chmod +x "$FT7/tmux"
    D7=$(mktemp -d "$TMP/rd7.XXXXXX")
    SLUG7=$(printf '%s' "$D7" | tr '/.' '--')
    mkdir -p "$WF7/cfg/projects/$SLUG7"
    S7A=aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa
    S7B=bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb
    for s in "$S7A" "$S7B"; do
        printf '{"type":"user","cwd":"%s"}\n' "$D7" > "$WF7/cfg/projects/$SLUG7/$s.jsonl"
    done
    # Older, but still inside --scan's window: a fixture outside it is filtered
    # by find and never reaches the ordering under test.
    touch -t "$(fmt_epoch $(( $(date +%s) - 172800 )) %Y%m%d%H%M)" "$WF7/cfg/projects/$SLUG7/$S7B.jsonl"
    # A stat that refuses exactly one file: the transcript vanishing between
    # find and stat is the real shape, and it cannot be raced deterministically.
    STATSTUB=$(mktemp -d "$TMP/statstub.XXXXXX")
    cat > "$STATSTUB/stat" <<STATEOF
#!/bin/sh
for a in "\$@"; do
  case "\$a" in *"$S7A.jsonl") exit 1 ;; esac
done
exec $(command -v stat) "\$@"
STATEOF
    chmod +x "$STATSTUB/stat"
    out=$(sess "$WF7" PATH="$STATSTUB:$FT7:$PATH" -- resume --scan 999 -n 2>&1)
    report 1 "$(printf '%s' "$out" | grep -c 'would reopen' || true)" \
        "F7: a transcript whose mtime cannot be read is skipped, not offered"
    report yes "$(printf '%s' "$out" | grep -q "${S7B%%-*}" && echo yes || echo no)" \
        "F7: ... and the one that can be read is still offered"
    # Control: with a working stat both are offered, newest first.
    out=$(sess "$WF7" PATH="$FT7:$PATH" -- resume --scan 999 -n 2>&1)
    report 2 "$(printf '%s' "$out" | grep -c 'would reopen' || true)" \
        "F7: ... while a working stat offers both (the control)"
    report yes "$(printf '%s' "$out" | grep -m1 'would reopen' | grep -q "${S7A%%-*}" && echo yes || echo no)" \
        "F7: ... newest first"
fi

echo "--- S2: reboot and resume answer -h without tmux ---"

if ! have jq; then
    skip "S2: help without tmux" "no jq"
else
    WS2=$(world)
    printf '{"pid":%d,"sessionId":"%s","name":"n","status":"idle","tmux":"","messagingSocketPath":"","kind":"interactive","cwd":"%s","updatedAt":2}\n' \
        "$$" "$UUID" "$TMP" > "$WS2/cfg/sessions/$$.json"
    NOTMUX2=$(minipath tmux)
    out=$( (sess "$WS2" PATH="$NOTMUX2" -- reboot -h >/dev/null) 2>&1 ); rc=$?
    report 0 "$rc" "S2: reboot -h answers without tmux"
    report yes "$(printf '%s' "$out" | grep -q 'Usage: session reboot' && echo yes || echo no)" \
        "S2: ... with its usage"
    out=$( (sess "$WS2" PATH="$NOTMUX2" -- resume -h >/dev/null) 2>&1 ); rc=$?
    report 0 "$rc" "S2: resume -h answers without tmux"

    # A real reboot still refuses, and the reason it gives is now true: the
    # sessions live in the presence registry, not in tmux — what needs tmux is
    # the replay.
    out=$( (sess "$WS2" PATH="$NOTMUX2" -- reboot -y >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "S2: a real reboot without tmux still refuses"
    report yes "$(printf '%s' "$out" | grep -q 'session resume' && echo yes || echo no)" \
        "S2: ... naming the replay as what needs it"
    report no "$(printf '%s' "$out" | grep -q 'live in it' && echo yes || echo no)" \
        "S2: ... and no longer claiming the sessions live in tmux"
fi

echo "--- S3: the producers write no shell errors to a hook's stderr ---"

if ! have jq; then
    skip "S3: silent producers" "no jq"
else
    NW3=$(mktemp -d "$TMP/nw3.XXXXXX"); mkdir -p "$NW3/cfg"
    err=$( (printf '{"session_id":"%s"}' "$UUID" | sess "$NW3" -- --turn-end >/dev/null) 2>&1 ); rc=$?
    report 0  "$rc"  "S3: a lifecycle mode with no data root exits 0"
    report "" "$err" "S3: ... and writes nothing to stderr"
    err=$( (printf '{"session_id":"%s","prompt_id":"p1"}' "$UUID" | sess "$NW3" -- --hook >/dev/null) 2>&1 ); rc=$?
    report 0  "$rc"  "S3: --hook with no data root exits 0"
    report "" "$err" "S3: ... and writes nothing to stderr (it runs on every prompt)"
fi

echo "--- L1-1: one error path for an unresolvable day ---"

if ! have jq; then
    skip "L1-1: --date diagnosis" "no jq"
else
    WT1=$(world)
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3660 )) "$UUID" > "$WT1/data/turn-log.tsv"
    NOPERL1=$(minipath perl)
    # The date is fine and perl is missing, but --date carried a second, older
    # refusal that fired first and blamed the date — on the one path a person
    # reaches when auditing a past day.
    out=$( (sess "$WT1" PATH="$NOPERL1" SESSION_NOW=$NOON -- time --date 2026-08-01 >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "L1-1: --date on a host that cannot resolve a day exits 2"
    report no "$(printf '%s' "$out" | grep -q 'is not a date I can parse' && echo yes || echo no)" \
        "L1-1: ... without blaming a date that is fine"
    report yes "$(printf '%s' "$out" | grep -q 'day boundary' && echo yes || echo no)" \
        "L1-1: ... naming the day boundary as what could not be resolved"
    report yes "$(printf '%s' "$out" | grep -q -- "--date '2026-08-01'" && echo yes || echo no)" \
        "L1-1: ... and the day it was asked for"
    # Control: the same date on a host that can resolve it is answered.
    report 60 "$(sess "$WT1" SESSION_NOW=$NOON -- time --date "$(fmt_epoch "$DAY0" %F)" --json | jq -r '.active_s')" \
        "L1-1: ... while a resolvable --date still reports (the control)"

    # Free text without GNU date: the lib's refusal names the accepted shapes,
    # and the second line now points at it instead of contradicting it.
    BSDT=$(mktemp -d "$TMP/bsdt.XXXXXX")
    printf '#!/bin/sh\ncase "${1:-}" in -d) exit 1;; esac\nexec %s "$@"\n' "$(command -v date)" > "$BSDT/date"
    chmod +x "$BSDT/date"
    out=$( (sess "$WT1" PATH="$BSDT:$PATH" SESSION_NOW=$NOON -- time --date 'three fridays hence' >/dev/null) 2>&1 )
    report yes "$(printf '%s' "$out" | grep -q "YYYY-MM-DD" && echo yes || echo no)" \
        "L1-1: free text without GNU date still names the shapes that are accepted"
    report no "$(printf '%s' "$out" | grep -q 'is not a date I can parse' && echo yes || echo no)" \
        "L1-1: ... and is not followed by a vaguer second opinion"

    # Those shapes are --date's, not the lib's. epoch_of takes five and
    # --date takes two of them, so a message written in the lib's vocabulary
    # sent whoever was already wrong to try four spellings this flag rejects —
    # quoting back a string they never typed, because the caller appends
    # " 00:00" before asking. The lib's own message is unchanged for anyone
    # calling epoch_of directly (case 11 pins it).
    out=$( (sess "$WT1" SESSION_NOW=$NOON -- time --date 2026-02-30 >/dev/null) 2>&1 ); rc=$?
    first=$(printf '%s\n' "$out" | sed -n '1p')
    report 2 "$rc" "date refusal: an impossible date exits 2"
    report yes "$(grep -q -- "--date '2026-02-30'" <<<"$first" && echo yes || echo no)" \
        "date refusal: the refusal echoes the string the user typed"
    report no "$(grep -q '00:00' <<<"$out" && echo yes || echo no)" \
        "date refusal: ... never the ' 00:00' the caller built, nor the lib's own shapes"
    report yes "$(grep -q 'YYYY-MM-DD' <<<"$first" && echo yes || echo no)" \
        "date refusal: ... and names the shapes --date accepts"
    report no "$(grep -q -- '+1 day' <<<"$out" && echo yes || echo no)" \
        "date refusal: ... not the internal ones it does not"
    # Control: a date this flag does accept still answers.
    report 60 "$(sess "$WT1" SESSION_NOW=$NOON -- time --date "$(fmt_epoch "$DAY0" %F)" --json | jq -r '.active_s')" \
        "date refusal: ... while a real YYYY-MM-DD still reports (the control)"
fi

echo "--- L1-2: the doctor does not attribute a provenance it cannot know ---"

if ! have jq; then
    skip "L1-2: data-root provenance" "no jq"
else
    WT2=$(world); mklogin "$WT2" me@example.com; chmod 700 "$WT2/data"
    CONFROOT="$TMP/confroot-t2"; mkdir -p "$CONFROOT"; chmod 700 "$CONFROOT"
    printf 'SESSION_DATA_DIR="${SESSION_DATA_DIR:-%s}"\n' "$CONFROOT" > "$WT2/cfg/session.conf"
    # The conf names one root and the environment another. Sourcing the conf
    # sets the variable either way, so after the fact the two are
    # indistinguishable — and the old wording asserted the conf had won while
    # printing the environment's root beside it.
    out=$(doctor19 "$WT2" "$CW" SESSION_DATA_DIR="$WT2/data")
    report yes "$(printf '%s' "$out" | grep -qE "^  ok +data root +$WT2/data " && echo yes || echo no)" \
        "L1-2: the data-root line names the root that actually resolved"
    report no "$(printf '%s' "$out" | grep -q 'set by .*session.conf' && echo yes || echo no)" \
        "L1-2: ... without claiming session.conf is what set it"
    report yes "$(printf '%s' "$out" | grep -q 'also sets' && echo yes || echo no)" \
        "L1-2: ... while still naming session.conf as a candidate"
    # Control: with no conf at all, the environment is named on its own.
    rm -f "$WT2/cfg/session.conf"
    out=$(doctor19 "$WT2" "$CW" SESSION_DATA_DIR="$WT2/data")
    report yes "$(printf '%s' "$out" | grep -q 'from SESSION_DATA_DIR' && echo yes || echo no)" \
        "L1-2: with no conf, the variable is named on its own (the control)"
    report no "$(printf '%s' "$out" | grep -q 'also sets' && echo yes || echo no)" \
        "L1-2: ... and no candidate is invented"
fi

echo "--- prologue: CDPATH and a symlink loop ---"

# The walk runs before anything else in the file, so a wrong answer here picks
# a different lib and every path in the CLI moves with it. The CLI is invoked
# as `<dir>/session` from the clone's parent, whatever the clone is named: a
# bare directory operand is the shape `cd` consults CDPATH for.
DECOY=$(mktemp -d "$TMP/decoy.XXXXXX")
SNAME=${SDIR##*/}
mkdir -p "$DECOY/$SNAME"
( cd "$SDIR/.." && out=$(env -i PATH="$PATH" HOME="$FH" TZ=UTC CDPATH="$DECOY" \
      CLAUDE_CODE_SESSION_ID="$UUID" timeout 30 bash "$SNAME/session" whoami --id 2>&1); rc=$?
  printf '%s\n%s\n' "$rc" "$out" ) > "$TMP/cdpath.out"
report 0 "$(sed -n '1p' "$TMP/cdpath.out")" "prologue: a CDPATH in the environment does not redirect the lib lookup"
report "$UUID" "$(sed -n '2p' "$TMP/cdpath.out")" "prologue: ... and the CLI answers normally"

# The walk is bounded at 40 hops like realpath_of. A chain longer than that is
# refused by the kernel before bash opens the script at all (measured: 45 links
# is ELOOP, and a true loop never reaches the walk), so the bound costs nothing
# a real install could want — what it must not do is break a legal chain.
CHAIN=$(mktemp -d "$TMP/chain.XXXXXX")
prev="$SDIR/session"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    ln -s "$prev" "$CHAIN/link$i"; prev="$CHAIN/link$i"
done
report "$UUID" "$(env -i PATH="$PATH" HOME="$FH" TZ=UTC CLAUDE_CODE_SESSION_ID="$UUID" \
    timeout 30 bash "$prev" whoami --id 2>&1)" \
    "prologue: a 20-link chain to the CLI still finds its lib"
out=$( (timeout 20 bash "$CHAIN/loop" whoami --id >/dev/null) 2>&1 ); rc=$?
report yes "$([ "$rc" != 124 ] && echo yes || echo no)" \
    "prologue: a path that cannot be opened fails fast rather than spinning"


# ═══════════════════════════════════════════════════════════════════════════════
# Coverage the port shipped without: tiers that are documented and touched by
# the port, but that no case ever ran. Smoke depth on purpose — these
# assert that each tier produces its shape and its integers, not golden values.
# ═══════════════════════════════════════════════════════════════════════════════

# A session-log row is 21 columns; only a few carry meaning to these readers.
# 1 ts · 2 sid · 3 cumulative $ · 4 5h% · 5 wk% · 6 5h resets_at · 7 wk resets_at
# 8 cumulative api ms · 21 login (the attribution filter).
slog_row() {  # TS SID COST FIVE_PCT WK_PCT FIVE_RESET WK_RESET APIMS LOGIN
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    printf '\t-%.0s' 9 10 11 12 13 14 15 16 17 18 19 20
    printf '\t%s\n' "$9"
}

echo "--- cov: --wait ---"

if ! have jq; then
    skip "cov: --wait" "no jq"
else
    WCW=$(world); mklogin "$WCW" me@example.com
    NOWI=$(date +%s)
    # A target already in the past: the wait returns at once and says the window
    # it was armed against had already turned over. This is the documented
    # behaviour, and the only way to exercise the block without sleeping.
    mkcache "$WCW" me@example.com 90 20 $(( NOWI - 600 )) $(( NOWI - 6000 ))
    out=$(sess "$WCW" -- --wait 5h); rc=$?
    report 0 "$rc" "cov: --wait 5h with a target already past returns at once"
    report yes "$(printf '%s' "$out" | grep -q '5-hour usage window reset' && echo yes || echo no)" \
        "cov: ... naming the window"
    report yes "$(printf '%s' "$out" | grep -q 'already past it' && echo yes || echo no)" \
        "cov: ... and saying the snapshot was already past it rather than implying it waited"
    out=$(sess "$WCW" -- --wait week); rc=$?
    report 0 "$rc" "cov: --wait week likewise"
    report yes "$(printf '%s' "$out" | grep -q 'weekly usage window reset' && echo yes || echo no)" \
        "cov: ... naming the weekly window"

    # No reset timestamp at all: there is nothing to wait for, and guessing
    # would block for a day.
    mkcache "$WCW" me@example.com 90 20 0 0
    out=$( (sess "$WCW" -- --wait 5h >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "cov: --wait with no reset timestamp in the cache refuses"
    report yes "$(printf '%s' "$out" | grep -q 'cannot wait' && echo yes || echo no)" \
        "cov: ... saying so"
fi

echo "--- cov: usage attribution ---"

if ! have jq; then
    skip "cov: usage" "no jq"
else
    WCU=$(world); mklogin "$WCU" me@example.com
    NOWI=$(date +%s); FR=$(( NOWI + 600 )); WR=$(( NOWI + 6000 ))
    mkcache "$WCU" me@example.com 50 20 "$FR" "$WR"
    { slog_row $(( NOWI - 300 )) "$UUID"  1.0 10 5 "$FR" "$WR" 1000 me@example.com
      slog_row $(( NOWI - 100 )) "$UUID"  3.0 30 9 "$FR" "$WR" 2000 me@example.com
      slog_row $(( NOWI - 200 )) "$UUID2" 4.0 20 7 "$FR" "$WR" 1500 me@example.com
      slog_row $(( NOWI - 150 )) "$UUID2" 5.0 25 8 "$FR" "$WR" 1800 me@example.com
      slog_row $(( NOWI - 120 )) "$UUID2" 9.0 26 8 "$FR" "$WR" 1900 other@example.com
    } > "$WCU/data/session-log.tsv"

    j=$(sess "$WCU" -- usage --json); rc=$?
    report 0 "$rc" "cov: usage --json exits 0"
    report "me@example.com" "$(printf '%s' "$j" | jq -r '.account')" "cov: ... keyed by the invoking login"
    report "$UUID" "$(printf '%s' "$j" | jq -r '.id')" "cov: ... for the invoking session"
    report true "$(printf '%s' "$j" | jq -r '.five_hour.tracked_usd == 2')" \
        "cov: ... counting this session's in-window cost deltas"
    report true "$(printf '%s' "$j" | jq -r '.five_hour.tracked_total_usd == 3')" \
        "cov: ... against the tracked total, which excludes the other login's rows"
    report number "$(printf '%s' "$j" | jq -r '.five_hour.est_pct_of_limit|type')" \
        "cov: ... with an estimated share as a number"

    a=$(sess "$WCU" -- usage --all --json); rc=$?
    report 0 "$rc" "cov: usage --all --json exits 0"
    report 2 "$(printf '%s' "$a" | jq -r '.sessions|length')" \
        "cov: ... one row per tracked session of this login, and only this login"
    report "true" "$(printf '%s' "$a" | jq -r --arg s "$UUID" '.sessions[]|select(.id==$s)|.current')" \
        "cov: ... marking the invoking one"
    report 0 "$(printf '%s' "$a" | grep -c 'ro''ost' || true)" "cov: ... and naming no host path"

    out=$(sess "$WCU" -- usage); rc=$?
    report 0 "$rc" "cov: the text rendering exits 0"
    report yes "$(printf '%s' "$out" | grep -q "$UUID" && echo yes || echo no)" "cov: ... naming the session"
    out=$(sess "$WCU" -- usage --all); rc=$?
    report 0 "$rc" "cov: usage --all exits 0"
    report yes "$(printf '%s' "$out" | grep -q 'tracked' && echo yes || echo no)" "cov: ... with the tracked totals row"
fi

echo "--- cov: usage attribution with two processes on one session id ---"

if ! have jq; then
    skip "cov: usage two processes" "no jq"
else
    # A `--resume` started beside the live original: two processes render under
    # one session id, each with its own cumulative cost, and both log every
    # render. Column 8 is each process's cumulative wall clock. The original
    # (clock ~100000 ms, cost 40 → 40.5 → 41) and the newcomer (clock ~1000 ms,
    # cost 0 → 0.2 → 0.4) interleave; the real in-window spend is 1.0 + 0.4 =
    # 1.4. A delta taken per sid instead of per process would book 40 + 40 +
    # 40.3 + ... of alternations — the shape that once reported $617,590 for one
    # session.
    WCP=$(world); mklogin "$WCP" me@example.com
    NOWI=$(date +%s); FR=$(( NOWI + 600 )); WR=$(( NOWI + 6000 ))
    mkcache "$WCP" me@example.com 50 20 "$FR" "$WR"
    { slog_row $(( NOWI - 300 )) "$UUID" 40.0 10 5 "$FR" "$WR" 100000 me@example.com
      slog_row $(( NOWI - 290 )) "$UUID"  0.0 10 5 "$FR" "$WR"   1000 me@example.com
      slog_row $(( NOWI - 280 )) "$UUID" 40.5 10 5 "$FR" "$WR" 110000 me@example.com
      slog_row $(( NOWI - 270 )) "$UUID"  0.2 10 5 "$FR" "$WR"   2000 me@example.com
      slog_row $(( NOWI - 260 )) "$UUID" 41.0 10 5 "$FR" "$WR" 120000 me@example.com
      slog_row $(( NOWI - 250 )) "$UUID"  0.4 10 5 "$FR" "$WR"   3000 me@example.com
    } > "$WCP/data/session-log.tsv"
    j=$(sess "$WCP" -- usage --json); rc=$?
    report 0 "$rc" "cov: usage --json with two processes on one sid exits 0"
    report true "$(printf '%s' "$j" | jq -r '.five_hour.tracked_usd == 1.4')" \
        "cov: ... counting each process's own growth (1.0 + 0.4), never the alternation between them"
    report true "$(printf '%s' "$j" | jq -r '.five_hour.tracked_total_usd == 1.4')" \
        "cov: ... and the tracked total agrees"
    # Rows from the older schema carry no clock: they fall into one stream, which
    # is the per-sid rule they were logged under.
    { slog_row $(( NOWI - 300 )) "$UUID" 1.0 10 5 "$FR" "$WR" "" me@example.com
      slog_row $(( NOWI - 200 )) "$UUID" 3.0 10 5 "$FR" "$WR" "" me@example.com
    } > "$WCP/data/session-log.tsv"
    j=$(sess "$WCP" -- usage --json)
    report true "$(printf '%s' "$j" | jq -r '.five_hour.tracked_usd == 2')" \
        "cov: ... rows without a clock still sum as one stream"
fi

echo "--- cov: time --all, --spans, and the rows nothing read back ---"

if ! have jq; then
    skip "cov: time --all/--spans" "no jq"
else
    WCT=$(world)
    # A turn carrying every intra-turn event the lifecycle dispatcher writes:
    # a subagent pair and a permission prompt. Case 2 writes these rows; until
    # now nothing checked that `session time` reads them back.
    printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\ta\tp1\texplore\tag1\n%s\t%s\tz\tp1\texplore\tag1\n%s\t%s\tp\tp1\t-\t-\n%s\t%s\te\tp1\t-\t-\n' \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3620 )) "$UUID" $(( DAY0 + 3680 )) "$UUID" \
        $(( DAY0 + 3700 )) "$UUID" $(( DAY0 + 3900 )) "$UUID" > "$WCT/data/turn-log.tsv"
    printf '%s\t%s\ts\tq1\t-\t-\n%s\t%s\te\tq1\t-\t-\n' \
        $(( DAY0 + 5000 )) "$UUID2" $(( DAY0 + 5100 )) "$UUID2" >> "$WCT/data/turn-log.tsv"
    printf '%s.000\tin\tpts/9\tvsc-a\t%%14\t%s\n%s.000\tout\tpts/9\tvsc-a\t%%14\t%s\n' \
        $(( DAY0 + 3600 )) "$UUID" $(( DAY0 + 3800 )) "$UUID" > "$WCT/data/focus-log.tsv"

    j=$(sess "$WCT" SESSION_NOW=$NOON SESSION_ATTEND_GRACE=600 -- time --json)
    report 1   "$(printf '%s' "$j" | jq -r '.subagents')" "cov: a subagent start/stop pair is counted"
    report 60  "$(printf '%s' "$j" | jq -r '.waits_s')"   "cov: ... and its duration summed"
    report 1   "$(printf '%s' "$j" | jq -r '.prompts')"   "cov: a permission prompt is counted"
    report 300 "$(printf '%s' "$j" | jq -r '.active_s')"  "cov: ... without any of them ending the turn"

    out=$(sess "$WCT" SESSION_NOW=$NOON SESSION_ATTEND_GRACE=600 -- time --all); rc=$?
    report 0 "$rc" "cov: time --all exits 0"
    report 2 "$(printf '%s' "$out" | grep -cE '^  [0-9a-f]{8} ' || true)" \
        "cov: ... one row per session with turns today"
    report yes "$(printf '%s' "$out" | grep -q '^  you ' && echo yes || echo no)" \
        "cov: ... plus the wall-clock union row"

    out=$(sess "$WCT" SESSION_NOW=$NOON SESSION_ATTEND_GRACE=600 -- time --spans); rc=$?
    report 0 "$rc" "cov: time --spans exits 0"
    report "$UUID	$(( DAY0 + 3600 )).000	$(( DAY0 + 3800 )).000" \
        "$(printf '%s' "$out" | awk 'NR==1{printf "%s\t%s\t%s", $1, $2, $3}')" \
        "cov: ... printing the attended interval as sid, start, end"

    # A session with focus but no turns today still gets a row in --all.
    printf '%s.000\tin\tpts/12\tvsc-b\t%%15\t%s\n%s.000\tout\tpts/12\tvsc-b\t%%15\t%s\n' \
        $(( DAY0 + 6000 )) 33333333-3333-3333-3333-333333333333 \
        $(( DAY0 + 6100 )) 33333333-3333-3333-3333-333333333333 >> "$WCT/data/focus-log.tsv"
    out=$(sess "$WCT" SESSION_NOW=$NOON SESSION_ATTEND_GRACE=600 -- time --all)
    report yes "$(printf '%s' "$out" | grep -q '^  33333333 ' && echo yes || echo no)" \
        "cov: an attended-only session still gets a row"
fi

echo "--- cov: an interrupted turn is credited to its last evidence ---"

if ! have jq; then
    skip "cov: g evidence" "no jq"
else
    WCG=$(world)
    # An unpaired start: no Stop hook fires on an interrupt, so the turn never
    # closes. The recovery credits it up to the last statusline sample whose
    # cumulative API duration grew — proof the model was still producing.
    printf '%s\t%s\ts\tp1\t-\t-\n' $(( DAY0 + 3600 )) "$UUID" > "$WCG/data/turn-log.tsv"
    j=$(sess "$WCG" SESSION_NOW=$NOON -- time --json)
    report 0 "$(printf '%s' "$j" | jq -r '.active_s')" \
        "cov: an unpaired start with no evidence beside it credits nothing"

    { slog_row $(( DAY0 + 3650 )) "$UUID" 1.0 10 5 0 0 100 me@example.com
      slog_row $(( DAY0 + 3700 )) "$UUID" 2.0 10 5 0 0 200 me@example.com
      slog_row $(( DAY0 + 3800 )) "$UUID" 3.0 10 5 0 0 300 me@example.com
    } > "$WCG/data/session-log.tsv"
    j=$(sess "$WCG" SESSION_NOW=$NOON -- time --json)
    report 200 "$(printf '%s' "$j" | jq -r '.active_s')" \
        "cov: a growing API duration is evidence, and the turn is credited to the last one"
    report 0 "$(printf '%s' "$j" | jq -r '.turns')" "cov: ... while still counting as no closed turn"

    # A sample whose cumulative duration did NOT grow is not evidence.
    { slog_row $(( DAY0 + 3650 )) "$UUID" 1.0 10 5 0 0 100 me@example.com
      slog_row $(( DAY0 + 3900 )) "$UUID" 2.0 10 5 0 0 100 me@example.com
    } > "$WCG/data/session-log.tsv"
    report 0 "$(sess "$WCG" SESSION_NOW=$NOON -- time --json | jq -r '.active_s')" \
        "cov: ... and a flat one is not (the control)"
fi

echo "--- cov: the cross-session lookup's transcript fallback ---"

if ! have jq; then
    skip "cov: lookup slow path" "no jq"
else
    WCL=$(world)
    # No usage snapshot for this id, so the lookup falls through to the
    # transcript store — the path whose find the port rewrote off -printf.
    mkdir -p "$WCL/cfg/projects/-w-x"
    printf '{"type":"ai-title","aiTitle":"Routing evaluation"}\n' \
        > "$WCL/cfg/projects/-w-x/$UUID2.jsonl"
    report "Routing evaluation" "$(sess "$WCL" -- name "$UUID2")" \
        "cov: session name falls back to the transcript store when no snapshot matches"
    report "Routing evaluation" "$(sess "$WCL" -- name "${UUID2%%-*}")" \
        "cov: ... by id prefix too"
    report 1 "$( (sess "$WCL" -- name 00000000 >/dev/null 2>&1); echo $? )" \
        "cov: ... and still exits 1 when the store has no such id (the control)"

    # The title query's fallback is an index over the store, not a rescan: it
    # is built on the first query, refreshed only for transcripts modified
    # since, and served as-is for the rest.
    IDX="$WCL/data/title-index.tsv"
    report "$UUID2" "$(sess "$WCL" -- id 'routing eval' 2>/dev/null)" \
        "cov: session id resolves a title through the transcript store"
    report present "$([ -s "$IDX" ] && echo present || echo absent)" \
        "cov: ... which builds the title index under the data root"
    # /rename after the auto-title: custom wins, as it does for whoami/name.
    printf '{"type":"custom-title","customTitle":"Judge routing","sessionId":"%s"}\n' "$UUID2" \
        >> "$WCL/cfg/projects/-w-x/$UUID2.jsonl"
    report "$UUID2" "$(sess "$WCL" -- id 'judge routing' 2>/dev/null)" \
        "cov: a transcript modified since the index was built is re-read"
    report 1 "$( (sess "$WCL" -- id 'routing eval' >/dev/null 2>&1); echo $? )" \
        "cov: ... and its custom title replaces the auto-title for id queries too"
    # A title entry glued to the previous record on one line (seen once in a
    # real store): the title is still found.
    UUID3=3e000000-0000-0000-0000-000000000000
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}{"type":"ai-title","aiTitle":"Concatenated entry","sessionId":"%s"}\n' "$UUID3" \
        > "$WCL/cfg/projects/-w-x/$UUID3.jsonl"
    report "$UUID3" "$(sess "$WCL" -- id 'concatenated' 2>/dev/null)" \
        "cov: a title entry sharing its line with the previous record is still indexed"
    # Same content rewritten under the OLD mtime: the index answers, the
    # transcript is not re-read — the property that makes the query cheap.
    touch -r "$WCL/cfg/projects/-w-x/$UUID3.jsonl" "$TMP/tidx-ref"
    printf '{"type":"ai-title","aiTitle":"Rewritten quietly","sessionId":"%s"}\n' "$UUID3" \
        > "$WCL/cfg/projects/-w-x/$UUID3.jsonl"
    touch -r "$TMP/tidx-ref" "$WCL/cfg/projects/-w-x/$UUID3.jsonl"
    report "$UUID3" "$(sess "$WCL" -- id 'concatenated' 2>/dev/null)" \
        "cov: a transcript whose mtime has not moved is served from the index, not re-read"
    rm -f "$WCL/cfg/projects/-w-x/$UUID3.jsonl"
    report 1 "$( (sess "$WCL" -- id 'concatenated' >/dev/null 2>&1); echo $? )" \
        "cov: a transcript that is gone drops out of the index"
    # A backslash in a title (a pasted path) is matched by typing it: the
    # index stores the title raw and the query is not escape-processed.
    printf '{"type":"custom-title","customTitle":"Fix C:\\\\Users\\\\path bug","sessionId":"%s"}\n' "$UUID3" \
        > "$WCL/cfg/projects/-w-x/$UUID3.jsonl"
    report "$UUID3" "$(sess "$WCL" -- id 'C:\Users\path' 2>/dev/null)" \
        "cov: a backslash in a title is matched by a query containing it"
    # A store with no titled transcript yet: the empty index it builds is the
    # answer, not a reason to scan the store again on every query.
    WCE=$(world); mkdir -p "$WCE/cfg/projects/-w-y"
    printf '{"type":"user","message":"hi"}\n' > "$WCE/cfg/projects/-w-y/$UUID3.jsonl"
    sess "$WCE" -- id 'anything' >/dev/null 2>&1
    report present "$([ -f "$WCE/data/title-index.tsv" ] && echo present || echo absent)" \
        "cov: a store with no titled transcript still writes its (empty) index"
    report 0 "$(sess "$WCE" -- id 'anything' 2>&1 >/dev/null | grep -c 'building the title index')" \
        "cov: ... and the next query does not rebuild it"
fi

echo "--- cov: --file, a malformed guard spec, and --compact over a real cache ---"

if ! have jq; then
    skip "cov: --file/valid_spec/--compact" "no jq"
else
    WCM=$(world); mklogin "$WCM" me@example.com
    NOWI=$(date +%s)
    mkcache "$WCM" me@example.com 50 20 $(( NOWI + 600 )) $(( NOWI + 6000 ))

    # --file is the deliberate substitute for the unkeyed cache override the port deleted.
    ALT="$TMP/alt-cache.json"
    printf '{"rate_limits":{"five_hour":{"used_percentage":77,"resets_at":%s},"seven_day":{"used_percentage":11,"resets_at":%s}},"context_window":{"used_percentage":5},"model":{"display_name":"Fable 5"}}\n' \
        $(( NOWI + 600 )) $(( NOWI + 6000 )) > "$ALT"
    report 77 "$(sess "$WCM" -- --file "$ALT" --json | jq -r '.rate_limits.five_hour.used_percentage')" \
        "cov: --file reads the cache it is given, not the login's"
    report 50 "$(sess "$WCM" -- --json | jq -r '.rate_limits.five_hour.used_percentage')" \
        "cov: ... and without it the login's cache is still what is read (the control)"

    # A typo in a guard spec has to error rather than silently disable pacing.
    out=$( (sess "$WCM" FIVE_GUARD=lienar -- --guard >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "cov: a malformed FIVE_GUARD exits 2"
    report yes "$(printf '%s' "$out" | grep -q 'invalid FIVE_GUARD' && echo yes || echo no)" \
        "cov: ... naming the variable and the accepted forms"
    out=$( (sess "$WCM" WEEK_GUARD='pow:x' -- --guard >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "cov: a malformed power curve exits 2 too"
    report 0 "$( (sess "$WCM" FIVE_GUARD='pow:0.5' WEEK_GUARD=off -- --guard >/dev/null) 2>&1; echo $? )" \
        "cov: ... while a well-formed one runs (the control)"

    # --compact over a populated cache: the frugal line every prompt hook emits.
    out=$(sess "$WCM" -- --compact); rc=$?
    report 0 "$rc" "cov: --compact over a populated cache exits 0"
    report yes "$(printf '%s' "$out" | grep -q '5h 50% used' && echo yes || echo no)" \
        "cov: ... carrying the five-hour percentage"
    report yes "$(printf '%s' "$out" | grep -q 'wk 20% used' && echo yes || echo no)" \
        "cov: ... and the weekly one"
    report yes "$(printf '%s' "$out" | grep -q 'resets to 0% in' && echo yes || echo no)" \
        "cov: ... with the countdown worded as a reset, not a deadline"
    report yes "$(printf '%s' "$out" | grep -q '· account me@example.com' && echo yes || echo no)" \
        "cov: ... and the account tag, since this config dir is not the primary one"
    report 1 "$(printf '%s' "$out" | grep -c . )" "cov: ... on exactly one line"
fi

echo "--- warn-thr: USAGE_WARN_PCT is one declaration, validated for both consumers ---"

if ! have jq; then
    skip "warn-thr: USAGE_WARN_PCT" "no jq"
else
    # One default, in one place. Two copies drift, and the consumer holding the
    # stale one gates at a threshold nobody chose.
    report 1 "$(grep -c 'USAGE_WARN_PCT:-90' "$BIN")" "warn-thr: the default 90 is written exactly once"

    WWT=$(world); mklogin "$WWT" me@example.com
    WTHOOK=$(printf '{"session_id":"%s","prompt_id":"p1"}' "$UUID")
    WTREW=$(printf '{"session_id":"%s","hook_event_name":"UserPromptSubmit"}' "$UUID")

    # The waiter fails closed without a claude ancestor, so reaching its use of
    # the threshold at all needs one. Same shape as case 17's, kept local so this
    # block stands on its own.
    cat > "$TMP/wt-asclaude.sh" <<'WTEOF'
b=$1; shift
timeout 60 bash "$b" "$@"
WTEOF
    wt_rewake() {  # [VAR=VAL ...] -- <session args>
        local e=""
        while [ $# -gt 0 ] && [ "$1" != -- ]; do e="$e $1"; shift; done
        [ "${1:-}" = -- ] && shift
        env -i PATH="$PATH" HOME="$FH" TZ=UTC \
            CLAUDE_CONFIG_DIR="$WWT/cfg" SESSION_DATA_DIR="$WWT/data" \
            CLAUDE_CODE_SESSION_ID="$UUID" $e \
            bash -c 'exec -a claude bash "$@"' _ "$TMP/wt-asclaude.sh" "$BIN" "$@"
    }

    NOWI=$(date +%s)
    mkcache "$WWT" me@example.com 95 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))

    # An ALPHABETIC value is the case that matters. `(( fp >= thr ))` re-expands
    # a non-numeric thr as a variable name, and under `set -u` an unset one kills
    # the shell — inside a hook, where nothing surfaces the death. Refusing with
    # exit 2 and a named variable is what makes the typo visible.
    out=$( (printf '%s' "$WTHOOK" | sess "$WWT" USAGE_WARN_PCT=ninety -- --hook) 2>"$TMP/wt.err" ); rc=$?
    report 2 "$rc" "warn-thr: an alphabetic USAGE_WARN_PCT exits 2 on the hook path"
    report yes "$(grep -q "invalid USAGE_WARN_PCT='ninety'" "$TMP/wt.err" && echo yes || echo no)" \
        "warn-thr: ... naming the variable and the value it refused"
    report no "$(grep -q 'unbound variable' "$TMP/wt.err" && echo yes || echo no)" \
        "warn-thr: ... instead of dying inside the arithmetic"
    report "" "$out" "warn-thr: ... and emitting no hook JSON"

    err=$( (printf '%s' "$WTREW" | wt_rewake USAGE_WARN_PCT=ninety -- --rewake-waiter >/dev/null) 2>&1 ); rc=$?
    report 2 "$rc" "warn-thr: the rewake path refuses the same value"
    report yes "$(printf '%s' "$err" | grep -q "invalid USAGE_WARN_PCT='ninety'" && echo yes || echo no)" \
        "warn-thr: ... with the same message, so the validation is reached from both consumers"

    # Non-integer generally, not just alphabetic. A decimal is the quiet half of
    # the same bug: the arithmetic itself fails, so the gate never fires and the
    # hook stays silent at any usage at all.
    rc=$( (printf '%s' "$WTHOOK" | sess "$WWT" USAGE_WARN_PCT=90.5 -- --hook >/dev/null 2>&1); echo $? )
    report 2 "$rc" "warn-thr: a decimal is refused too"

    # Above 100 is not an error: it is the documented way to turn the hook's
    # output off, and no consumer may break on it.
    out=$(printf '%s' "$WTHOOK" | sess "$WWT" USAGE_WARN_PCT=150 -- --hook 2>/dev/null); rc=$?
    report 0 "$rc" "warn-thr: a threshold above 100 leaves the hook exiting 0"
    report "" "$out" "warn-thr: ... injecting nothing at 95% used"
    rc=$( (printf '%s' "$WTREW" | wt_rewake USAGE_WARN_PCT=150 -- --rewake-waiter >/dev/null 2>&1); echo $? )
    report 0 "$rc" "warn-thr: ... and the waiter exits 0"
    report absent "$([ -e "$WWT/data/sessions/$UUID.rewaiter" ] && echo present || echo absent)" \
        "warn-thr: ... arming nothing"

    # Digits only is not yet a number: bash reads a leading zero as octal, so an
    # unnormalised 070 gates at 56 and 09 fails the arithmetic outright. That is
    # the same silent mis-gating the check above exists to close, one base later.
    mkcache "$WWT" me@example.com 60 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))
    report "" "$(printf '%s' "$WTHOOK" | sess "$WWT" USAGE_WARN_PCT=070 -- --hook 2>/dev/null)" \
        "warn-thr: 070 is seventy, not octal fifty-six, so 60% used stays quiet"
    mkcache "$WWT" me@example.com 95 10 $(( NOWI + 3600 )) $(( NOWI + 36000 ))
    err=$( (printf '%s' "$WTHOOK" | sess "$WWT" USAGE_WARN_PCT=09 -- --hook >"$TMP/wt09.out") 2>&1 )
    report yes "$(jq -r '.hookSpecificOutput.additionalContext // ""' "$TMP/wt09.out" | grep -q '5h rate limit at 95%' && echo yes || echo no)" \
        "warn-thr: ... and 09 is nine, not a base error that silences the gate"
    report "" "$err" "warn-thr: ... leaving nothing on stderr"

    # The control: with nothing set, 95% still crosses the default 90.
    ctx=$(printf '%s' "$WTHOOK" | sess "$WWT" -- --hook 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext')
    report yes "$(printf '%s' "$ctx" | grep -q '5h rate limit at 95%' && echo yes || echo no)" \
        "warn-thr: with nothing set the default 90 still gates"

    # session.conf is the only channel that reaches a hook — tmux, cron and the
    # harness inherit no shell environment — and the declaration's
    # environment-wins form is what makes a conf line land without any plumbing.
    printf 'USAGE_WARN_PCT="${USAGE_WARN_PCT:-98}"\n' > "$WWT/cfg/session.conf"
    chmod 600 "$WWT/cfg/session.conf"
    report "" "$(printf '%s' "$WTHOOK" | sess "$WWT" -- --hook 2>/dev/null)" \
        "warn-thr: session.conf raises the threshold, and 95% no longer warns"
    report yes "$(printf '%s' "$WTHOOK" | sess "$WWT" USAGE_WARN_PCT=50 -- --hook 2>/dev/null \
        | jq -r '.hookSpecificOutput.additionalContext' | grep -q '5h rate limit at 95%' && echo yes || echo no)" \
        "warn-thr: ... while the environment still wins over the conf"
    rm -f "$WWT/cfg/session.conf"
fi

echo "--- case 14 [swap]: the credential swap is confirmed against the file it wrote ---"

if ! have jq; then
    skip "case 14 [swap]: the swap post-condition" "no jq"
else
    # A write that reports success and lands something else is not a swap, and
    # the post-condition is what makes that visible: it reads .credentials.json
    # back and compares the
    # installed claudeAiOauth with the vault entry's — the credential itself, not
    # the login name, because the name lives in .claude.json, which a concurrent
    # session rewrites from memory and which this fixture leaves correct on
    # purpose: a check against it would confirm a swap that did not land.
    W14s=$(world); VS="$W14s/vault"
    mklogin "$W14s" a@example.com
    printf '{"claudeAiOauth":{"accessToken":"tok-a","expiresAt":1},"mcpOAuth":{"granola":"keep-me"}}\n' > "$W14s/cfg/.credentials.json"
    sess "$W14s" SESSION_ACCOUNTS_DIR="$VS" -- account save >/dev/null 2>&1
    mklogin "$W14s" b@example.com
    printf '{"claudeAiOauth":{"accessToken":"tok-b","expiresAt":2},"mcpOAuth":{"granola":"keep-me"}}\n' > "$W14s/cfg/.credentials.json"
    sess "$W14s" SESSION_ACCOUNTS_DIR="$VS" -- account save >/dev/null 2>&1

    # The control: an untampered swap, so the case below is about the check and
    # not about the fixture.
    out=$(sess "$W14s" SESSION_ACCOUNTS_DIR="$VS" -- account use a@ 2>&1); rc=$?
    report 0 "$rc" "case 14 [swap]: an untampered swap exits 0"
    report "tok-a" "$(jq -r '.claudeAiOauth.accessToken' "$W14s/cfg/.credentials.json")" \
        "case 14 [swap]: ... installing the vault entry's credential"

    # A jq that rewrites the one filter the credential swap uses and passes every
    # other call through: the write succeeds, the wrong token lands.
    TJ=$(mktemp -d "$TMP/tamperjq.XXXXXX")
    { printf '#!/usr/bin/env bash\nRJQ=%s\n' "$(command -v jq)"
      cat <<'TAMPEREOF'
args=()
for x in "$@"; do
    [ "$x" = '.claudeAiOauth = $v[0].claudeAiOauth' ] && \
        x='.claudeAiOauth = ($v[0].claudeAiOauth | .accessToken = "tok-tampered")'
    args+=("$x")
done
exec "$RJQ" "${args[@]}"
TAMPEREOF
    } > "$TJ/jq"
    chmod +x "$TJ/jq"

    out=$( (sess "$W14s" PATH="$TJ:$PATH" SESSION_ACCOUNTS_DIR="$VS" -- account use b@) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [swap]: a write that lands a different credential exits 1"
    report yes "$(printf '%s' "$out" | grep -q 'did not land' && echo yes || echo no)" \
        "case 14 [swap]: ... saying the swap was not observed"
    report no "$(printf '%s' "$out" | grep -qE 'tok-b|tok-tampered' && echo yes || echo no)" \
        "case 14 [swap]: ... and rendering no token value while saying so"
    report "b@example.com" "$(jq -r '.oauthAccount.emailAddress' "$W14s/cfg/.claude.json")" \
        "case 14 [swap]: ... although the identity file names the incoming login (what makes it the wrong witness)"

    # An entry with no claudeAiOauth key at all carries no token either, so it
    # is refused on the same ground as an empty one and installs nothing.
    cp "$W14s/cfg/.credentials.json" "$TMP/creds.before.nokey"
    printf '{"email":"c@example.com","login":"c@example.com","oauthAccount":{"emailAddress":"c@example.com"}}\n' \
        > "$VS/c@example.com.json"
    out=$( (sess "$W14s" SESSION_ACCOUNTS_DIR="$VS" -- account use c@) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [swap]: a vault entry carrying no credential at all exits 1"
    report yes "$(printf '%s' "$out" | grep -q '/login' && echo yes || echo no)" \
        "case 14 [swap]: ... refused as unusable rather than announced as a switch"
    report yes "$(cmp -s "$TMP/creds.before.nokey" "$W14s/cfg/.credentials.json" && echo yes || echo no)" \
        "case 14 [swap]: ... with the live credentials byte-identical"

    # The write-failure arm: nothing is installed and the message names the write.
    FJ=$(mktemp -d "$TMP/failjq.XXXXXX")
    { printf '#!/usr/bin/env bash\nRJQ=%s\n' "$(command -v jq)"
      cat <<'FAILEOF'
for x in "$@"; do
    [ "$x" = '.claudeAiOauth = $v[0].claudeAiOauth' ] && exit 5
done
exec "$RJQ" "$@"
FAILEOF
    } > "$FJ/jq"
    chmod +x "$FJ/jq"
    cp "$W14s/cfg/.credentials.json" "$TMP/creds.before"
    out=$( (sess "$W14s" PATH="$FJ:$PATH" SESSION_ACCOUNTS_DIR="$VS" -- account use a@) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [swap]: a credentials write that fails exits 1"
    report yes "$(printf '%s' "$out" | grep -q 'failed to write credentials' && echo yes || echo no)" \
        "case 14 [swap]: ... naming the write as what failed"
    report yes "$(cmp -s "$TMP/creds.before" "$W14s/cfg/.credentials.json" && echo yes || echo no)" \
        "case 14 [swap]: ... leaving the live credentials byte-identical"
    report "" "$(ls -a "$W14s/cfg" | grep '\.swap\.' || true)" \
        "case 14 [swap]: ... and no temp file behind"

    # A vault entry that cannot authenticate is refused before anything is
    # written, not after. Installing it is how a human turns one dead login
    # into a machine with nothing left able to authenticate, and it is reached
    # by hand exactly during the outage that makes them reach for it: five
    # entries with a zero-length accessToken are on this machine already.
    cp "$W14s/cfg/.credentials.json" "$TMP/creds.before.dead"
    cp "$W14s/cfg/.claude.json" "$TMP/claude.before.dead"
    live14s=$(jq -r '.oauthAccount.emailAddress' "$W14s/cfg/.claude.json")
    printf '{"email":"d@example.com","login":"d@example.com","oauthAccount":{"emailAddress":"d@example.com"},"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0}}\n' \
        > "$VS/d@example.com.json"
    out=$( (sess "$W14s" SESSION_ACCOUNTS_DIR="$VS" -- account use d@) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [swap]: a vault entry whose accessToken is empty exits 1"
    report yes "$(printf '%s' "$out" | grep -q 'd@example.com' && echo yes || echo no)" \
        "case 14 [swap]: ... naming the login whose entry is unusable"
    report yes "$(printf '%s' "$out" | grep -q '/login' && echo yes || echo no)" \
        "case 14 [swap]: ... and pointing at /login, since a retry cannot help"
    report no "$(printf '%s' "$out" | grep -q 'failed to write' && echo yes || echo no)" \
        "case 14 [swap]: ... rather than blaming the write, which never ran"
    report yes "$(cmp -s "$TMP/creds.before.dead" "$W14s/cfg/.credentials.json" && echo yes || echo no)" \
        "case 14 [swap]: ... leaving the live credentials byte-identical"
    report yes "$(cmp -s "$TMP/claude.before.dead" "$W14s/cfg/.claude.json" && echo yes || echo no)" \
        "case 14 [swap]: ... and the identity file untouched, so the live login does not move"
    report "$live14s" "$(jq -r '.oauthAccount.emailAddress' "$W14s/cfg/.claude.json")" \
        "case 14 [swap]: ... which still names the login it named before"

    # The null shape, which is also on this machine: a claudeAiOauth that is
    # not an object at all carries no token to install either.
    printf '{"email":"e@example.com","login":"e@example.com","oauthAccount":{"emailAddress":"e@example.com"},"claudeAiOauth":null}\n' \
        > "$VS/e@example.com.json"
    out=$( (sess "$W14s" SESSION_ACCOUNTS_DIR="$VS" -- account use e@) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [swap]: a vault entry whose claudeAiOauth is null exits 1 the same way"
    report yes "$(printf '%s' "$out" | grep -q 'e@example.com' && echo yes || echo no)" \
        "case 14 [swap]: ... naming that login too"
    report yes "$(cmp -s "$TMP/creds.before.dead" "$W14s/cfg/.credentials.json" && echo yes || echo no)" \
        "case 14 [swap]: ... and installing nothing"
fi

echo "--- case 14 [blank credential]: an empty accessToken is never vaulted ---"

if ! have jq; then
    skip "case 14 [blank credential]" "no jq"
else
    # Recorded five times in two months: .credentials.json holds a complete
    # claudeAiOauth object — every key present, every type right — whose
    # accessToken is "". The autosave vaulted it over the last working copy of
    # that login, it went live, and nothing on the box could authenticate for
    # 10.5 hours. Both recorded shapes are here: expiresAt 0, and expiresAt
    # absent, both with the refresh token blanked alongside. The keys are the
    # seven Claude Code writes, in the order it writes them.
    blank() {  # WORLD EXPIRES_FRAGMENT — the live credential, token blank
        printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"",%s"refreshTokenExpiresAt":0,"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"default"},"mcpOAuth":{"granola":"keep-me"}}\n' \
            "$2" > "$1/cfg/.credentials.json"
    }
    WBC=$(world); VBC="$WBC/vault"; VFBC="$VBC/a@example.com.json"
    mklogin "$WBC" a@example.com
    printf '{"claudeAiOauth":{"accessToken":"tok-good","refreshToken":"rt-a","expiresAt":1,"refreshTokenExpiresAt":0,"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"default"},"mcpOAuth":{"granola":"keep-me"}}\n' \
        > "$WBC/cfg/.credentials.json"
    sess "$WBC" SESSION_ACCOUNTS_DIR="$VBC" -- account save >/dev/null 2>&1
    report yes "$([ -s "$VFBC" ] && echo yes || echo no)" \
        "case 14 [blank]: a working login vaults (the control)"
    KEEP=$(cat "$VFBC")

    blank "$WBC" '"expiresAt":0,'
    out=$( (sess "$WBC" SESSION_ACCOUNTS_DIR="$VBC" -- account save >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [blank]: save exits 1 on an empty accessToken with expiresAt 0"
    report yes "$([ "$KEEP" = "$(cat "$VFBC")" ] && echo yes || echo no)" \
        "case 14 [blank]: ... leaving the vault entry byte-identical"
    report 0 "$(ls -1 "$VBC/.history" 2>/dev/null | grep -c . || true)" \
        "case 14 [blank]: ... and rotating nothing into .history"
    report yes "$(printf '%s' "$out" | grep -q 'accessToken' && echo yes || echo no)" \
        "case 14 [blank]: ... saying on stderr why nothing was saved"

    blank "$WBC" ''
    out=$( (sess "$WBC" SESSION_ACCOUNTS_DIR="$VBC" -- account save >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [blank]: save exits 1 on an empty accessToken with no expiresAt at all"
    report yes "$([ "$KEEP" = "$(cat "$VFBC")" ] && echo yes || echo no)" \
        "case 14 [blank]: ... leaving the vault entry byte-identical here too"

    # A null claudeAiOauth is the same refusal on the same test — it too has
    # been written to the vault on this machine, one second after a healthy
    # save. A token that is absent rather than empty vaults nothing usable.
    printf '{"claudeAiOauth":null,"mcpOAuth":{"granola":"keep-me"}}\n' > "$WBC/cfg/.credentials.json"
    out=$( (sess "$WBC" SESSION_ACCOUNTS_DIR="$VBC" -- account save >/dev/null) 2>&1 ); rc=$?
    report 1 "$rc" "case 14 [blank]: save exits 1 on a null claudeAiOauth"
    report yes "$([ "$KEEP" = "$(cat "$VFBC")" ] && echo yes || echo no)" \
        "case 14 [blank]: ... leaving the vault entry byte-identical there too"

    # Only the empty token is refused. A token with no expiresAt beside it is a
    # valid live shape and still vaults, so the refusal cannot widen into one.
    printf '{"claudeAiOauth":{"accessToken":"tok-new"}}\n' > "$WBC/cfg/.credentials.json"
    out=$(sess "$WBC" SESSION_ACCOUNTS_DIR="$VBC" -- account save 2>&1); rc=$?
    report 0 "$rc" "case 14 [blank]: a non-empty token with no expiresAt still vaults"
    report "tok-new" "$(jq -r '.claudeAiOauth.accessToken' "$VFBC")" \
        "case 14 [blank]: ... replacing the entry"

    # `doctor` is where a human sees the state while it is happening, so it has
    # to name the entry the refusal is protecting.
    BBC=$(mktemp -d "$TMP/bbc.XXXXXX"); ln -sf "$BIN" "$BBC/session"
    chmod 700 "$WBC/data"
    dbc() {  # WORLD VAULT -> doctor output
        ( cd "$TMP" && env -i PATH="$BBC:$PATH" HOME="$FH" TZ=UTC \
            CLAUDE_CONFIG_DIR="$1/cfg" SESSION_DATA_DIR="$1/data" \
            SESSION_ACCOUNTS_DIR="$2" CLAUDE_CODE_SESSION_ID="$UUID" \
            timeout 60 bash "$BIN" doctor 2>&1 )
    }
    out=$(dbc "$WBC" "$VBC"); rc=$?
    report 0 "$rc" "case 14 [blank]: doctor over a working live credential exits 0"
    report 0 "$(printf '%s' "$out" | awk '$2 == "credentials"' | grep -c . || true)" \
        "case 14 [blank]: ... and prints no credentials line (nothing to report)"

    blank "$WBC" '"expiresAt":0,'
    out=$(dbc "$WBC" "$VBC"); rc=$?
    report 1 "$rc" "case 14 [blank]: doctor exits 1 while the live credential is blank"
    report FAIL "$(printf '%s' "$out" | awk '$2 == "credentials" { print $1; exit }')" \
        "case 14 [blank]: ... failing the credentials line"
    report yes "$(printf '%s' "$out" | grep -qF -- "$VFBC" && echo yes || echo no)" \
        "case 14 [blank]: ... naming the vault entry it is preserving"

    # The same blank with nothing vaulted for that login: there is no copy to
    # restore from, and saying so is the whole content of the report.
    WBC2=$(world); chmod 700 "$WBC2/data"; mklogin "$WBC2" c@example.com
    blank "$WBC2" '"expiresAt":0,'
    out=$(dbc "$WBC2" "$WBC2/vault"); rc=$?
    report FAIL "$(printf '%s' "$out" | awk '$2 == "credentials" { print $1; exit }')" \
        "case 14 [blank]: doctor fails the credentials line with an empty vault too"
    report yes "$(printf '%s' "$out" | grep -q 'no vaulted copy' && echo yes || echo no)" \
        "case 14 [blank]: ... and says there is no copy to restore from"

    # A vault entry that is itself blank was reachable before this refusal
    # existed, and pointing a human at it during an outage would reinstall the
    # blank. Existing is not the same as usable, and the line must not say it is.
    mkdir -p "$WBC2/vault"
    printf '{"login":"c@example.com","claudeAiOauth":{"accessToken":"","expiresAt":0}}\n' \
        > "$WBC2/vault/c@example.com.json"
    out=$(dbc "$WBC2" "$WBC2/vault")
    report yes "$(printf '%s' "$out" | grep -q 'no vaulted copy' && echo yes || echo no)" \
        "case 14 [blank]: a vault entry whose own token is empty is not offered as the copy to restore"
    report no "$(printf '%s' "$out" | grep -q 'last working copy' && echo yes || echo no)" \
        "case 14 [blank]: ... and is not called a working copy"
fi

echo "--- case 20: the pure selector ---"

# Pure functions: no files, no clock, no network, nothing read from a global.
# So the case sources lib/account.sh directly and drives every predicate from
# literals — no world, no vault, no curl stub, no subprocess `session`.
# shellcheck source=/dev/null
. "$SDIR/lib/account.sh"

# ── acct_num: the cell vocabulary, asserted by value ────────────────────────
# `~0%` is the one that must be checked by value rather than "an integer or
# -1": it is what a window whose reset has already passed renders as, which
# makes that login the BEST candidate, and reading it as the unknown sentinel
# would make the best candidate inadmissible while every other criterion
# stayed green. The subshell's exit status is asserted on every spelling
# because under `set -u` an arithmetic expansion of a non-numeric cell
# re-expands it as a variable name and kills the process silently.
while IFS='|' read -r n20in n20want; do
    n20got=$(acct_num "$n20in"); rc=$?
    report "$n20want" "$n20got" "case 20: acct_num [$n20in]"
    report 0 "$rc" "case 20: ... and returns 0, so the spelling does not kill the shell"
done <<'NUM20EOF'
12%|12
~0%|0
n/a|-1
-|-1
?|-1
102|102
~0|0
100%|100
|-1
abc|-1
5h|-1
12.5%|-1
-1|-1
NUM20EOF

# ── acct_blocked: which windows are spent, in canonical order ───────────────
report fable  "$(acct_blocked 90 2 65 100 0)"   "case 20: acct_blocked names the Fable window alone"
report -      "$(acct_blocked 90 2 65 40 0)"    "case 20: ... and a dash when nothing is spent"
report 5h     "$(acct_blocked 90 103 31 54 0)"  "case 20: ... a five-hour window over 100%"
report 5h,week,fable "$(acct_blocked 90 95 95 95 0)" "case 20: ... all three in canonical order"
report 5h     "$(acct_blocked 90 90 10 10 0)"   "case 20: ... at the threshold, not merely above it"
report fable  "$(acct_blocked 90 '~0%' '65%' '100%' 0)" "case 20: ... over raw table cells as well as integers"
report 5h     "$(acct_blocked 90 -1 10 10 1)"   "case 20: an unknown window blocks when UNKNOWN_BLOCKS=1"
report -      "$(acct_blocked 90 -1 10 10 0)"   "case 20: ... and does not when it is 0"
report fable  "$(acct_blocked 90 10 10 -1 1)"   "case 20: ... which is what caps an unknown-Fable candidate at tier 1"
report -      "$(acct_blocked 101 100 100 100 0)" "case 20: a threshold above every figure blocks nothing"

# ── acct_tier: the capability ladder ────────────────────────────────────────
report 2 "$(acct_tier -)"             "case 20: acct_tier 2 — nothing blocked, every model served"
report 1 "$(acct_tier fable)"         "case 20: acct_tier 1 — only Fable blocked, still good for Opus"
report 0 "$(acct_tier 5h)"            "case 20: acct_tier 0 — a spent five-hour window serves nothing"
report 0 "$(acct_tier week)"          "case 20: ... same for the weekly"
report 0 "$(acct_tier 5h,fable)"      "case 20: ... and a general window drags a Fable block down with it"
report 0 "$(acct_tier week,fable)"    "case 20: ... in either combination"
report 0 "$(acct_tier 5h,week,fable)" "case 20: ... and when all three are spent"
report 2 "$(acct_tier '')" "case 20: an empty list is the same empty list a dash spells"

# ── acct_admissible: a switch has to climb the ladder ───────────────────────
adm() { acct_admissible "$1" "$2" && echo yes || echo no; }
report yes "$(adm - fable)"     "case 20: tier 2 over a Fable-spent live login is admissible"
report yes "$(adm fable 5h)"    "case 20: a Fable-spent candidate over a tier-0 live login is admissible"
report yes "$(adm - 5h)"        "case 20: ... as is a clean one"
report no  "$(adm fable fable)" "case 20: an equal tier is refused"
report no  "$(adm - -)"         "case 20: ... at the top of the ladder too"
report no  "$(adm fable -)"     "case 20: and a lower tier is refused outright"
report no  "$(adm 5h fable)"    "case 20: ... including a candidate that serves nothing"

# ── acct_rank and the whole policy, over a real account table ──────────────
# The four figures per row are a real vault's, captured 2026-09-22 while the
# live login stood at 5h 2% / week 65% / Fable 100%; only the names are
# anonymised. Three of the four logins had spent their Fable weekly while
# their general windows read healthy, and the one login with Fable headroom
# was over its own five-hour cap — "no candidate is clean on every window" is
# the ordinary state of this box, not an edge case, which is the whole reason
# the policy is a ladder rather than a set. Row 2 keeps the organisation-seat
# name shape, where the bare email is a prefix of the seat's name.
TBL20=$(printf '%s\t%s\t%s\t%s\t%s\n' \
    'one@example.com'     'probe' 21  52 100 \
    'one@example.com+org' 'probe' 103 31 54  \
    'two@example.com'     'probe' 52  54 100)

# What the decision verb does with these five functions: rank the candidates,
# then admit the winner — the winner carries the highest tier, so it is
# admissible iff any candidate is. UNKNOWN_BLOCKS=1 because these are
# candidates: an unknown general window fails them closed, and an unknown Fable
# window caps them at tier 1.
pick20() {  # LIVE_BLOCKS  (rows on stdin) -> the login the switcher would move to
    local liveb="$1" tbl win row f5 wk fb
    tbl=$(cat)
    win=$(printf '%s\n' "$tbl" | acct_rank 90)
    [ -n "$win" ] || return 0
    row=$(printf '%s\n' "$tbl" | awk -F'\t' -v l="$win" '$1 == l { print; exit }')
    IFS=$'\t' read -r _ _ f5 wk fb <<<"$row"
    acct_admissible "$(acct_blocked 90 "$f5" "$wk" "$fb" 1)" "$liveb" && printf '%s\n' "$win"
    return 0
}

# The same table with the first login's Fable at 40%: the one thing that has
# to change for the switcher to move at all.
TBL20B=$(printf '%s\t%s\t%s\t%s\t%s\n' \
    'one@example.com'     'probe' 21  52 40  \
    'one@example.com+org' 'probe' 103 31 54  \
    'two@example.com'     'probe' 52  54 100)

report "" "$(printf '%s\n' "$TBL20" | pick20 fable)" \
    "case 20: the captured table yields no candidate — every login is tier 1 or 0"
report 'one@example.com' "$(printf '%s\n' "$TBL20B" | pick20 fable)" \
    "case 20: ... until one login's Fable drops to 40%, and tier 2 beats tier 1"
report 'one@example.com' "$(printf '%s\n' "$TBL20" | pick20 5h)" \
    "case 20: a tier-0 live login moves to a Fable-spent candidate — it serves every other model"
report "" "$(printf 'a\tprobe\t100\t100\t100\n' | pick20 5h)" \
    "case 20: ... but never to another tier-0 login"
report bbb "$(printf 'aaa\tprobe\t100\t0\t0\nbbb\tprobe\t80\t80\t100\n' | pick20 5h)" \
    "case 20: a tier-0 candidate is never chosen, whatever its headroom"
report "" "$(printf 'aaa\tprobe\t0\t0\t0\n' | pick20 -)" \
    "case 20: equal tiers never switch, even when the candidate has far more headroom"
report bbb "$(printf 'aaa\tprobe\t-\tn/a\t?\nbbb\tprobe\t50\t50\t50\n' | pick20 fable)" \
    "case 20: a row of sentinels never wins"
report "" "$(printf 'aaa\tprobe\t-\tn/a\t?\n' | pick20 fable)" \
    "case 20: ... and on its own it is no candidate at all"

report bbb "$(printf 'aaa\tprobe\t10\t10\t95\nbbb\tfrozen\t10\t10\t10\n' | acct_rank 90)" \
    "case 20: acct_rank puts the highest tier first, ahead of probe freshness"
report bbb "$(printf 'aaa\tfrozen\t10\t10\t10\nbbb\tprobe\t50\t50\t50\n' | acct_rank 90)" \
    "case 20: ... then probe-verified ahead of frozen, whatever the headroom"
report aaa "$(printf 'aaa\tprobe\t10\t10\t100\nbbb\tprobe\t50\t50\t95\n' | acct_rank 90)" \
    "case 20: ... then the worst window among the ones the tier depends on — Fable is spent on both, so it does not rank them"
report bbb "$(printf 'aaa\tprobe\t10\t10\t80\nbbb\tprobe\t50\t50\t50\n' | acct_rank 90)" \
    "case 20: ... while at tier 2 Fable does rank them, so the row with 80% there loses to one at 50% everywhere"
report aaa "$(printf 'bbb\tprobe\t10\t10\t10\naaa\tprobe\t10\t10\t10\n' | acct_rank 90)" \
    "case 20: ... and a tie breaks on the name"
report 'B@example.com' "$(printf 'B@example.com\tprobe\t10\t10\t10\na@example.com\tprobe\t10\t10\t10\n' | acct_rank 90)" \
    "case 20: ... collated as bytes, so the answer does not move with the machine's locale"
report aaa "$(printf 'aaa\tprobe\t9\t9\t9\nbbb\tprobe\t10\t10\t10\n' | acct_rank 90)" \
    "case 20: ... and the windows compare as numbers, so 10% does not outrank 9% on its first digit"
report "" "$(printf '' | acct_rank 90)" "case 20: no rows, no winner"
report aaa "$(printf 'aaa\tprobe\t10\t10\t10\n' | acct_rank 90)" "case 20: one row wins on its own"
report aaa "$(printf '\naaa\tprobe\t50\t50\t50\n' | acct_rank 90)" \
    "case 20: a blank row cannot suppress a real candidate — it is tier 0 and frozen by construction"
report "" "$(printf '\n' | acct_rank 90)" "case 20: ... and on its own it wins nothing"

echo "--- wake-target: a spent Fable window is what the waiter sleeps to ---"

if ! have jq; then
    skip "wake-target: the Fable wake target" "no jq"
else
    mkfable() {  # WORLD LOGIN PCT RESET — the file `session account list|use` caches
        printf '{"fable":{"used_percentage":%s,"resets_at":%s}}\n' "$3" "$4" \
            > "$1/data/fable.$2.json"
    }

    # A simulated clock, so a target an hour out is reached in no real time.
    # `sleep` records a tick instead of sleeping and `date +%s` reports 400 s
    # per tick — one step wider than the waiter's 300 s sleep chunk, so every
    # chunk lands past its own end and the loop converges in a few ticks.
    # inotifywait is stubbed for the same reason: where it is installed,
    # flip_wait blocks on it for the whole chunk.
    FBB=$(mktemp -d "$TMP/fbbin.XXXXXX")
    FBBASE=$(date +%s)
    FBDATE=$(command -v date)
    cat > "$FBB/sleep" <<TICKEOF
#!/bin/sh
echo tick >> "$FBB/ticks"
exit 0
TICKEOF
    cat > "$FBB/inotifywait" <<'INOEOF'
#!/bin/sh
exit 0
INOEOF
    cat > "$FBB/date" <<CLKEOF
#!/bin/sh
case "\$*" in
  *%s*) n=\$(grep -c . "$FBB/ticks" 2>/dev/null)
        echo \$(( $FBBASE + \${n:-0} * 400 )) ;;
  *)    exec "$FBDATE" "\$@" ;;
esac
CLKEOF
    chmod +x "$FBB/sleep" "$FBB/inotifywait" "$FBB/date"

    WFB=$(world); mklogin "$WFB" me@example.com
    FBCAP=$(printf '{"session_id":"%s","hook_event_name":"StopFailure","error_type":"rate_limit"}' "$UUID")

    # The waiter fails closed without a claude ancestor, so reaching the arming
    # arm at all needs one. Same shape as case 17's, kept local so this block
    # stands on its own.
    cat > "$TMP/fb-asclaude.sh" <<'FBAEOF'
b=$1; shift
timeout 60 bash "$b" "$@"
FBAEOF
    fb_rewake() {  # one waiter run on the simulated clock, from a fresh tick count
        : > "$FBB/ticks"
        rm -f "$WFB/data/sessions/$UUID.rewaiter"
        env -i PATH="$FBB:$PATH" HOME="$FH" TZ=UTC \
            CLAUDE_CONFIG_DIR="$WFB/cfg" SESSION_DATA_DIR="$WFB/data" \
            CLAUDE_CODE_SESSION_ID="$UUID" \
            bash -c 'exec -a claude bash "$@"' _ "$TMP/fb-asclaude.sh" "$BIN" --rewake-waiter
    }
    # The waiter's exit code IS the wake-up, so the run's status is returned and
    # the wake-up text goes to a file: a `$(...)` capture would put the status
    # in a subshell the assertions cannot read.
    FBERR="$TMP/fb.err"
    fbwake() { (printf '%s' "$FBCAP" | fb_rewake >/dev/null) 2>"$FBERR"; }
    fbsaid() { grep -q "$1" "$FBERR" && echo yes || echo no; }
    # How far the waiter actually slept, in simulated 300 s chunks: the only
    # observable that distinguishes WHICH reset it slept to, since the wake-up
    # text is chosen beside the target rather than derived from it. A target at
    # +4000 takes ten chunks, one at +200 takes one, and a target already past
    # takes none.
    fbticks() { grep -c . "$FBB/ticks"; }
    fb_armed() { [ -e "$WFB/data/sessions/$UUID.rewaiter" ] && echo present || echo absent; }

    # The measured common case: a 5h reset IS ahead, so today the waiter sleeps
    # to it, wakes into the same Fable cap and dies again. 53 of 68 model-scoped
    # cap deaths over 53 days took that loop.
    mkcache "$WFB" me@example.com 10 10 $(( FBBASE + 200 )) $(( FBBASE + 300 ))
    mkfable "$WFB" me@example.com 95 $(( FBBASE + 4000 ))
    fbwake; rc=$?
    report 2 "$rc" "wake-target: a cap death with the live login's Fable window spent wakes the session"
    report yes "$(fbsaid 'Fable weekly rate-limit window has reset')" \
        "wake-target: ... naming the Fable window"
    report 10 "$(fbticks)" \
        "wake-target: ... and having slept to the Fable reset, not the 5h one that does not lift it"

    # The other measured shape: nothing ahead in the cache at all, where today
    # the waiter does not arm and the session waits for a human.
    mkcache "$WFB" me@example.com 10 10 $(( FBBASE - 100 )) $(( FBBASE - 50 ))
    fbwake; rc=$?
    report 2 "$rc" "wake-target: ... and it arms although both cached generic resets are stale"
    report yes "$(fbsaid 'Fable weekly rate-limit window has reset')" \
        "wake-target: ... naming the same window"
    report 10 "$(fbticks)" "wake-target: ... and sleeping to the same target"

    # At or above the threshold, so the boundary itself arms.
    mkfable "$WFB" me@example.com 90 $(( FBBASE + 4000 ))
    fbwake; rc=$?
    report 2 "$rc" "wake-target: a figure exactly at the warn threshold is spent enough to retarget"
    report 10 "$(fbticks)" "wake-target: ... to the Fable reset"

    # fable.<login>.json is refreshed only by `session account list|use`, so a
    # figure below the threshold is routinely just old. Suppressing the retarget
    # is the deliberate half of that: unhelpful, never wrong.
    mkfable "$WFB" me@example.com 89 $(( FBBASE + 4000 ))
    fbwake; rc=$?
    report 0 "$rc" "wake-target: a figure below the threshold leaves today's behaviour alone"
    report absent "$(fb_armed)" "wake-target: ... arming nothing"

    # A window that has already turned over needs no wake at all.
    mkfable "$WFB" me@example.com 95 $(( FBBASE - 10 ))
    fbwake; rc=$?
    report 0 "$rc" "wake-target: a Fable reset already in the past leaves today's behaviour alone"
    report absent "$(fb_armed)" "wake-target: ... arming nothing"

    # Never a target the waiter cannot tell from one that has just passed: the
    # wake would land back inside the same cap and re-enter the loop.
    mkfable "$WFB" me@example.com 95 $(( FBBASE + 60 ))
    fbwake; rc=$?
    report 0 "$rc" "wake-target: a Fable reset at now+60 is not accepted"
    report absent "$(fb_armed)" "wake-target: ... arming nothing"
    mkfable "$WFB" me@example.com 95 $(( FBBASE + 61 ))
    fbwake; rc=$?
    report 2 "$rc" "wake-target: ... while one second past the floor is"
    report yes "$(fbsaid 'Fable weekly rate-limit window has reset')" \
        "wake-target: ... and wakes on it"

    # A half-written file is a shape the endpoint fetch can leave behind, and it
    # must read as "no figure", not as a figure of zero or of the shell's making.
    printf '{"fable":{"used_percen' > "$WFB/data/fable.me@example.com.json"
    fbwake; rc=$?
    report 0 "$rc" "wake-target: an unparseable Fable file leaves today's behaviour alone"
    report absent "$(fb_armed)" "wake-target: ... arming nothing"
    report "" "$(cat "$FBERR")" "wake-target: ... and says nothing on stderr"

    # Well-formed JSON whose numbers are not numbers. `(( p >= thr ))` re-expands
    # a non-numeric p as a VARIABLE NAME, and under `set -u` an unset one kills
    # the waiter — inside a hook, where the death surfaces as neither output nor
    # error and auto-resume is simply gone for the session.
    printf '{"fable":{"used_percentage":"lots","resets_at":%s}}\n' "$(( FBBASE + 4000 ))" \
        > "$WFB/data/fable.me@example.com.json"
    fbwake; rc=$?
    report 0 "$rc" "wake-target: a non-numeric Fable percentage leaves today's behaviour alone"
    report "" "$(cat "$FBERR")" "wake-target: ... without dying inside the arithmetic"
    printf '{"fable":{"used_percentage":95,"resets_at":"soon"}}\n' \
        > "$WFB/data/fable.me@example.com.json"
    fbwake; rc=$?
    report 0 "$rc" "wake-target: a non-numeric Fable reset does too"
    report "" "$(cat "$FBERR")" "wake-target: ... and likewise survives it"

    rm -f "$WFB/data/fable.me@example.com.json"
    fbwake; rc=$?
    report 0 "$rc" "wake-target: no Fable file at all leaves today's behaviour alone"
    report absent "$(fb_armed)" "wake-target: ... arming nothing"

    # The retarget is for the cap the generic windows cannot explain. A warned
    # 5h window is the harness's own attribution and keeps its reset, whatever
    # the Fable file beside it says.
    mkcache "$WFB" me@example.com 95 10 $(( FBBASE + 200 )) $(( FBBASE + 300 ))
    mkfable "$WFB" me@example.com 99 $(( FBBASE + 4000 ))
    fbwake; rc=$?
    report 2 "$rc" "wake-target: a warned 5h window still wakes on its own reset"
    report yes "$(fbsaid '5h rate-limit window has reset')" \
        "wake-target: ... named as the 5h window"
    report no "$(fbsaid Fable)" \
        "wake-target: ... with no mention of Fable"
    report 1 "$(fbticks)" \
        "wake-target: ... having slept to the 5h reset and not to the Fable one four thousand seconds out"
fi

echo "--- switch-log: the audit row, its readers, and the blank-credential refusal ---"

# The writer resolves its path per call, so these drive it in a subshell with
# the data root pointed at a fixture: the lib sourced at the top of this suite
# resolved SESSION_DATA to the store of the session RUNNING the suite, and
# nothing here may write there.
AL="$TMP/alog"; mkdir -p "$AL"
ALF="$AL/switch-log.tsv"
ALNOW=1000
al() { ( SESSION_DATA="$AL"; SESSION_NOW="$ALNOW"; "$@" ); }

# ── the writer ─────────────────────────────────────────────────────────────
al acct_log switch a@example.com b@example.com cap climbed \
    'a@example.com=21/52/100*;b@example.com=10/10/10*' 'tier=2;sid=s1'
report 1 "$(grep -c . "$ALF")" "switch-log: one call appends one row"
report 8 "$(awk -F'\t' 'NR==1{print NF}' "$ALF")" "switch-log: ... of exactly eight columns"
report "1000 switch a@example.com b@example.com cap climbed" \
    "$(awk -F'\t' 'NR==1{print $1, $2, $3, $4, $5, $6}' "$ALF")" \
    "switch-log: ... carrying the timestamp, the event, both logins, the trigger and the reason"
report 'a@example.com=21/52/100*;b@example.com=10/10/10*' "$(awk -F'\t' 'NR==1{print $7}' "$ALF")" \
    "switch-log: ... the figures the decision saw"
report 'tier=2;sid=s1' "$(awk -F'\t' 'NR==1{print $8}' "$ALF")" \
    "switch-log: ... and the detail bag last"

# An empty field does not survive `read` — tab is IFS whitespace, so a leading
# one is stripped and a run of them merges, shifting every field after it. The
# writer is what keeps that from ever arising, for every caller at once.
: > "$ALF"
al acct_log hold '' '' cap cooldown '' 'sid=s2'
report 8 "$(awk -F'\t' 'NR==1{print NF}' "$ALF")" \
    "switch-log: an empty argument still leaves eight columns"
report '- - -' "$(awk -F'\t' 'NR==1{print $3, $4, $7}' "$ALF")" \
    "switch-log: ... written as a dash, so no field in a row is ever empty"
report '8 cooldown sid=s2' "$(al acct_log_last | awk -F'\t' '{print NF, $6, $8}')" \
    "switch-log: ... and the row survives the reader with its later fields unshifted"

: > "$ALF"
al acct_log refuse a@example.com
report '8 refuse a@example.com - - - - -' \
    "$(awk -F'\t' 'NR==1{print NF, $2, $3, $4, $5, $6, $7, $8}' "$ALF")" \
    "switch-log: a caller that passes fewer arguments than there are columns still writes eight"

# ── acct_log_last ──────────────────────────────────────────────────────────
: > "$ALF"
al acct_log hold a@example.com - cap cooldown - 'sid=h1'
al acct_log switch a@example.com b@example.com cap climbed - 'tier=2'
report switch "$(al acct_log_last | awk -F'\t' '{print $2}')" \
    "switch-log: acct_log_last reads the newest row"
report 'hold sid=h1' "$(al acct_log_last hold | awk -F'\t' '{print $2, $8}')" \
    "switch-log: ... and with an event, the newest row of that event, whole"
report "" "$(al acct_log_last fail 2>/dev/null)" \
    "switch-log: an event with no row prints nothing"
report yes "$(al acct_log_last fail >/dev/null 2>&1 || echo yes)" \
    "switch-log: ... and says so in its exit status"
report yes "$( ( SESSION_DATA="$TMP/no-such-root"; acct_log_last ) >/dev/null 2>&1 || echo yes)" \
    "switch-log: so does a read with no log at all"

# ── acct_log_key: the newest row THAT CARRIES IT ───────────────────────────
# A refusal and a cooldown hold carry neither next_eligible= nor scoped=, and
# a caller that gets no output from the decision child — a busy lock, or that
# very cooldown — recovers the value from the log rather than re-probing. Read
# off the newest row alone, both would read as absent.
: > "$ALF"
al acct_log hold a@example.com - cap no-candidate - 'next_eligible=1758000000;scoped=1'
al acct_log refuse a@example.com - manual blank-credential - 'notify=sent'
al acct_log hold a@example.com - cap cooldown - 'sid=h3'
report 1758000000 "$(al acct_log_key next_eligible)" \
    "switch-log: a key the newest rows do not carry is read from the newest row that does"
report 1 "$(al acct_log_key scoped)" \
    "switch-log: ... which is also how doctor reads the probe's scoped-row count"
report yes "$(al acct_log_key tier >/dev/null 2>&1 || echo yes)" \
    "switch-log: a key no row carries exits non-zero"
al acct_log hold a@example.com - cap no-candidate - 'next_eligible=-'
report - "$(al acct_log_key next_eligible)" \
    "switch-log: a decision that computed the value and found none answers with its dash, not with the older epoch"

# ── a data root the writer cannot write ────────────────────────────────────
# No state means no decision: the caller has to hear about it rather than read
# a silent success and switch anyway.
if [ "$(id -u)" = 0 ]; then
    skip "switch-log: an unwritable data root" "running as root, which writes anyway"
else
    RO="$TMP/alog-ro"; mkdir -p "$RO"; chmod 500 "$RO"
    alout=$( ( SESSION_DATA="$RO"; acct_log hold a@example.com - cap cooldown - - ) 2>&1 ); alrc=$?
    report yes "$([ "$alrc" != 0 ] && echo yes || echo no)" \
        "switch-log: a data root it cannot write is reported to the caller, not swallowed"
    report "" "$alout" \
        "switch-log: ... without putting the shell's redirect error on a hook's stderr"
    chmod 700 "$RO"
fi

# ── retention: deliberately none ───────────────────────────────────────────
# ~1,500 rows a year against a 79 MB store, and the rows are the only record of
# why the box moved. The three live logs beside it keep 8 days.
ALPR="$TMP/alog-prune"; mkdir -p "$ALPR"
alold=$(( $(date +%s) - 90 * 86400 ))
printf '%s\tswitch\ta@example.com\tb@example.com\tcap\tclimbed\t-\t-\n' "$alold" > "$ALPR/switch-log.tsv"
printf '%s\tsid\told\n' "$alold" > "$ALPR/turn-log.tsv"
probe 'session_prune_daily' SESSION_DATA_DIR="$ALPR" SESSION_NOW="$(date +%s)"
report 1 "$(grep -c . "$ALPR/switch-log.tsv")" \
    "switch-log: the daily prune leaves a 90-day-old decision row where it is"
report 0 "$(grep -c . "$ALPR/turn-log.tsv" || true)" \
    "switch-log: ... while the live logs in the same root are pruned as usual"

# ── the blank-credential refusal records and announces itself ──────────────
if ! have jq; then
    skip "switch-log: the blank-credential refusal" "no jq"
else
    WAL=$(world); VAL="$WAL/vault"; ALOG="$WAL/data/switch-log.tsv"
    mklogin "$WAL" a@example.com
    printf '{"claudeAiOauth":{"accessToken":"tok-secret-a"},"mcpOAuth":{}}\n' > "$WAL/cfg/.credentials.json"
    sess "$WAL" SESSION_ACCOUNTS_DIR="$VAL" -- account save >/dev/null 2>&1
    ALNOTE="$TMP/alog-notified"; ALNOTIFY="$TMP/alog-notify.sh"
    printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s"\n' "$ALNOTE" > "$ALNOTIFY"; chmod 755 "$ALNOTIFY"
    printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0},"mcpOAuth":{}}\n' \
        > "$WAL/cfg/.credentials.json"
    alsave() {  # EPOCH — one autosave against the blank live credential
        sess "$WAL" SESSION_ACCOUNTS_DIR="$VAL" SESSION_SWITCH_NOTIFY="$ALNOTIFY" \
            SESSION_NOW="$1" -- account save >/dev/null 2>&1
    }
    alwait() {  # LINES — the seam is fired in the background, so poll for it
        local n=0
        while [ "$(grep -c . "$ALNOTE" 2>/dev/null || echo 0)" -lt "$1" ] && [ "$n" -lt 25 ]; do
            sleep 0.2 2>/dev/null || sleep 1
            n=$(( n + 1 ))
        done
    }
    alsave 2000
    report 1 "$(grep -c . "$ALOG" 2>/dev/null || true)" \
        "switch-log [refusal]: a refused blank credential writes one row"
    report 'refuse a@example.com - manual blank-credential -' \
        "$(awk -F'\t' 'NR==1{print $2, $3, $4, $5, $6, $7}' "$ALOG")" \
        "switch-log [refusal]: ... naming the login it refused and why"
    report 'notify=sent' "$(awk -F'\t' 'NR==1{print $8}' "$ALOG")" \
        "switch-log [refusal]: ... and recording that the seam was fired"
    alwait 1
    report 1 "$(grep -c . "$ALNOTE" 2>/dev/null || true)" \
        "switch-log [refusal]: the notify seam is called once"
    report yes "$(grep -q 'a@example.com' "$ALNOTE" && echo yes || echo no)" \
        "switch-log [refusal]: ... naming the login"
    report yes "$(grep -qF "$VAL/a@example.com.json" "$ALNOTE" && echo yes || echo no)" \
        "switch-log [refusal]: ... and the vault entry being preserved"

    # The refusal returns before the vault entry's touch, deliberately — a
    # touch would mark a blank as captured — so the statusline forks this save
    # on every render for as long as the live credential stays blank.
    alsave 2000
    report 1 "$(grep -c . "$ALOG")" \
        "switch-log [refusal]: a second refusal inside the cooldown writes no second row"
    alsave 2900
    alwait 2
    report 2 "$(grep -c . "$ALOG")" \
        "switch-log [refusal]: ... and at the cooldown, not merely past it, the state is recorded again"
    report 2 "$(grep -c . "$ALNOTE")" \
        "switch-log [refusal]: ... one notification per row and no more"
    report refuse "$(awk -F'\t' 'END{print $2}' "$ALOG")" \
        "switch-log [refusal]: both rows are refusals"

    report 0 "$(grep -c 'tok-secret-a' "$ALOG" || true)" \
        "switch-log [refusal]: no token value reaches the log"

    # With no seam configured there is nothing to fire, and the row says so
    # rather than claiming a notification nobody received.
    WAL2=$(world); VAL2="$WAL2/vault"
    mklogin "$WAL2" c@example.com
    printf '{"claudeAiOauth":{"accessToken":""},"mcpOAuth":{}}\n' > "$WAL2/cfg/.credentials.json"
    sess "$WAL2" SESSION_ACCOUNTS_DIR="$VAL2" SESSION_NOW=3000 -- account save >/dev/null 2>&1
    report 'notify=off' "$(awk -F'\t' 'NR==1{print $8}' "$WAL2/data/switch-log.tsv")" \
        "switch-log [refusal]: with no notify seam set, the row records that nothing was sent"
    report 'refuse c@example.com' "$(awk -F'\t' 'NR==1{print $2, $3}' "$WAL2/data/switch-log.tsv")" \
        "switch-log [refusal]: ... and the refusal is still recorded"

    # The limit is per LOGIN, so it has to survive another login's refusal
    # landing in the same log between two of this one's. `use` vaults the
    # OUTGOING login, and a human switching entries during an outage is exactly
    # when that interleaving happens.
    sess "$WAL2" SESSION_ACCOUNTS_DIR="$VAL2" SESSION_DATA_DIR="$WAL/data" \
        SESSION_NOW=2950 -- account save >/dev/null 2>&1
    report 3 "$(grep -c . "$ALOG")" \
        "switch-log [refusal]: another login's first refusal is recorded beside this one's"
    alsave 3000
    report 3 "$(grep -c . "$ALOG")" \
        "switch-log [refusal]: ... and does not reopen the first login's cooldown"
fi

echo "--- case 14 [probe]: the status-aware usage probe ---"

if ! have jq; then
    skip "case 14 [probe]" "no jq"
else
    # acct_probe is driven in process: the two libs are sourced under `env -i`
    # with a fixture data root, so the probe's cache writes land in the fixture
    # and never in the real store. `session` itself cannot be sourced (sourcing
    # it runs it), which is why the probe lives in the lib at all.
    cat > "$TMP/aprobe" <<'APEOF'
. "$SESSION_LIB_UNDER_TEST"      || { echo "cannot source lib/common.sh" >&2; exit 9; }
. "$SESSION_ACCT_LIB_UNDER_TEST" || { echo "cannot source lib/account.sh" >&2; exit 9; }
eval "$PROBE"
APEOF
    aprobe() {  # aprobe 'snippet' [VAR=VAL ...]
        local snippet="$1"; shift
        env -i PATH="$PATH" HOME="$FH" TZ="${TZ:-UTC}" \
            SESSION_LIB_UNDER_TEST="$LIB" SESSION_ACCT_LIB_UNDER_TEST="$SDIR/lib/account.sh" \
            PROBE="$snippet" ${1+"$@"} bash "$TMP/aprobe"
    }

    PB=$(curlstub)
    PD="$TMP/probe-data"; VFP="$TMP/probe-vault"; mkdir -p "$PD" "$VFP"
    NOWP=$(date +%s)
    pvent() {  # LOGIN TOKEN EXPIRES_AT [FILE_STEM] — the shape `account save` writes
        printf '{"email":"%s","login":"%s","oauthAccount":{"emailAddress":"%s"},"claudeAiOauth":{"accessToken":"%s","expiresAt":%s000}}\n' \
            "$1" "$1" "$1" "$2" "$3" > "$VFP/${4:-$1}.json"
    }
    pnone() { printf '%s\t-1\t-1\t-1\t0\t0\t0\t%s' "$1" "${2:-0}"; }
    pp() {  # LOGIN -> the probe's row for that login, under the stub
        aprobe "acct_probe '$1' '$VFP/$1.json'" SESSION_DATA_DIR="$PD" PATH="$PB:$PATH"
    }

    # The 200 body is the 2026-09-22 capture, trimmed to the fields the filter
    # reads: the flat five_hour/seven_day pair the endpoint carried before it
    # grew limits[], and the three limits rows it carries now.
    CAP5=1790076600   # 2026-09-22T11:30:00Z, the capture's five-hour reset
    CAPW=1790240400   # 2026-09-24T09:00:00Z, its weekly reset, shared with Fable
    pvent ok@example.com tk-ok $(( NOWP + 3600 ))
    printf '%s\n' '{"five_hour":{"utilization":24.0,"resets_at":"2026-09-22T11:30:00.301329+00:00"},"seven_day":{"utilization":48.0,"resets_at":"2026-09-24T09:00:00.301351+00:00"},"limits":[{"kind":"session","group":"session","percent":24,"severity":"normal","resets_at":"2026-09-22T11:30:00.301329+00:00","scope":null,"is_active":false},{"kind":"weekly_all","group":"weekly","percent":48,"severity":"normal","resets_at":"2026-09-24T09:00:00.301351+00:00","scope":null,"is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":89,"severity":"warning","resets_at":"2026-09-24T09:00:00.301571+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":true}]}' \
        > "$PB/body.tk-ok"

    r=$(pp ok@example.com)
    report "$(printf 'good\t24\t48\t89\t%s\t%s\t%s\t1' "$CAP5" "$CAPW" "$CAPW")" "$r" \
        "case 14 [probe]: the captured 200 is good, carrying both general windows, Fable, and each reset as an epoch"
    report 8 "$(printf '%s\n' "$r" | awk -F'\t' '{print NF}')" \
        "case 14 [probe]: ... in eight fields, none of them empty"
    report '{"fable":{"used_percentage":89,"resets_at":1790240400}}' "$(cat "$PD/fable.ok@example.com.json" 2>&1)" \
        "case 14 [probe]: ... and the same body refreshes the Fable cache through the pinned filter"
    report no "$([ -e "$PD/probe-body.ok@example.com.json" ] && echo yes || echo no)" \
        "case 14 [probe]: ... while a body that parsed is not kept on disk"

    # The flat shape alone — what the endpoint answered before it grew limits[].
    pvent flat@example.com tk-flat $(( NOWP + 3600 ))
    printf '%s\n' '{"five_hour":{"utilization":24.0,"resets_at":"2026-09-22T11:30:00.301329+00:00"},"seven_day":{"utilization":48.0,"resets_at":"2026-09-24T09:00:00.301351+00:00"}}' \
        > "$PB/body.tk-flat"
    report "$(printf 'good\t24\t48\t-1\t%s\t%s\t0\t0' "$CAP5" "$CAPW")" "$(pp flat@example.com)" \
        "case 14 [probe]: a body with no limits[] falls back to the flat five_hour/seven_day pair"

    # The deferred guard: the selector still looks only at Fable, but a second
    # model-scoped window is counted, so a shape change is visible the week it
    # happens instead of after a bad switch.
    pvent two@example.com tk-two $(( NOWP + 3600 ))
    printf '%s\n' '{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":89,"resets_at":"2026-09-24T09:00:00.301571+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}},{"kind":"weekly_scoped","group":"weekly","percent":12,"resets_at":"2026-09-24T09:00:00.301571+00:00","scope":{"model":{"id":null,"display_name":"Opus"},"surface":null}}]}' \
        > "$PB/body.tk-two"
    report "$(printf 'good\t-1\t-1\t89\t0\t0\t%s\t2' "$CAPW")" "$(pp two@example.com)" \
        "case 14 [probe]: a second model-scoped window is counted, and Fable's row is still the one read"

    # ── the status classification, which never reads the body ────────────────
    # A 429 is a 4xx, and this endpoint's rate bucket is selected by User-Agent:
    # an "any 4xx is dead" rule would mark healthy logins dead and, worse, mark
    # the live login blocked on everything and switch because we were throttled.
    printf '%s\n' '{"type":"error","error":{"type":"authentication_error","message":"OAuth access token is invalid."},"request_id":null}' > "$PB/body.tk-bad"
    printf '%s\n' '{"type":"error","error":{"type":"authentication_error","message":"OAuth access token has expired. Re-authenticate to continue."},"request_id":null}' > "$PB/body.tk-exp"
    while IFS='|' read -r pnm pcode pstate plabel; do
        [ -n "$pnm" ] || continue
        pvent "$pnm@example.com" "tk-$pnm" $(( NOWP + 3600 ))
        printf '%s' "$pcode" > "$PB/status.tk-$pnm"
        [ -f "$PB/body.tk-$pnm" ] || printf '%s\n' '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}' > "$PB/body.tk-$pnm"
        report "$(pnone "$pstate")" "$(pp "$pnm@example.com")" "case 14 [probe]: $plabel"
    done <<'PSTATUS'
bad|401|dead|an invalid access token is dead
exp|401|dead|... and so is an expired one, on the same status and without reading the message that differs
fbd|403|dead|a 403 is dead too
lim|429|unreachable|a 429 is unreachable, never dead — the endpoint throttled us, the login is fine
slw|408|unreachable|a 408 is unreachable
ise|500|unreachable|a 500 is unreachable
ovl|503|unreachable|a 503 is unreachable
gne|000|unreachable|a curl that never got a response is unreachable
PSTATUS
    report "" "$(cd "$PD" && ls | grep '^probe-body\.')" \
        "case 14 [probe]: not one of those states keeps a response body — only a 200 nothing can be read from does"

    # ── a 200 that parses to nothing: the shape change this has already seen ──
    pvent inband@example.com tk-inband $(( NOWP + 3600 ))
    printf '%s\n' '{"error":{"type":"rate_limit_error"}}' > "$PB/body.tk-inband"
    printf '{"fable":{"used_percentage":61,"resets_at":4070908800}}\n' > "$PD/fable.inband@example.com.json"
    cp "$PD/fable.inband@example.com.json" "$TMP/probe-fable-inband.before"
    report "$(pnone noshape)" "$(pp inband@example.com)" \
        "case 14 [probe]: a 200 whose body parses to no usable window at all is noshape"
    report '{"error":{"type":"rate_limit_error"}}' "$(cat "$PD/probe-body.inband@example.com.json" 2>&1)" \
        "case 14 [probe]: ... and that raw body is kept, because a shape change is the case it is evidence for"
    report yes "$(cmp -s "$TMP/probe-fable-inband.before" "$PD/fable.inband@example.com.json" && echo yes || echo no)" \
        "case 14 [probe]: ... while the previous Fable figure is left byte-identical"

    cp "$PB/body.tk-ok" "$PB/body.tk-inband"
    pp inband@example.com >/dev/null
    report no "$([ -e "$PD/probe-body.inband@example.com.json" ] && echo yes || echo no)" \
        "case 14 [probe]: ... and a body that parses again clears it, so its presence always means the LAST probe could not be read"

    pvent junk@example.com tk-junk $(( NOWP + 3600 ))
    printf '%s\n' 'not json at all' > "$PB/body.tk-junk"
    report "$(pnone noshape)" "$(pp junk@example.com)" \
        "case 14 [probe]: a 200 that is not JSON is noshape as well"

    # scoped_rows survives a noshape: the one figure that says the endpoint's
    # shape moved is worth nothing if it is dropped exactly when it moves.
    pvent nulp@example.com tk-nulp $(( NOWP + 3600 ))
    printf '%s\n' '{"limits":[{"kind":"weekly_scoped","group":"weekly","percent":null,"resets_at":null,"scope":{"model":{"id":null,"display_name":"Fable"},"surface":null}}]}' \
        > "$PB/body.tk-nulp"
    report "$(pnone noshape 1)" "$(pp nulp@example.com)" \
        "case 14 [probe]: a noshape still reports how many model-scoped rows it saw"

    # ── the two states that make no request at all ───────────────────────────
    pvent laps@example.com tk-laps $(( NOWP - 60 ))
    report "$(pnone lapsed)" "$(pp laps@example.com)" \
        "case 14 [probe]: a lapsed access token is lapsed"
    report no "$([ -e "$PB/asked.tk-laps" ] && echo yes || echo no)" \
        "case 14 [probe]: ... and is never sent, so nothing rotates the credential it belongs to"
    printf '{"email":"gap@example.com","login":"gap@example.com"}\n' > "$VFP/gap@example.com.json"
    report "$(pnone lapsed)" "$(pp gap@example.com)" \
        "case 14 [probe]: a vault entry with no readable token is lapsed too — nothing was asked, so nothing is known"
    report "$(pnone nocurl)" \
        "$(aprobe "acct_probe ok@example.com '$VFP/ok@example.com.json'" SESSION_DATA_DIR="$PD" PATH="$(minipath curl)")" \
        "case 14 [probe]: a host without curl probes nothing and says so, so the decision falls back to frozen figures"

    report "" "$(cd "$PD" && ls | grep '\.tmp\.')" \
        "case 14 [probe]: no temp file is left behind by any of those states"
    report 0 "$(grep -c 'tk-' "$PB/argv" || true)" \
        "case 14 [probe]: across every one of them the token reached curl on stdin, never in its argv"

    # ── the fan-out: one file per login, read after wait ─────────────────────
    # Two logins with different answers, so a merged pipe or a shared temp file
    # shows up as a row carrying the other login's figures rather than as a
    # crash. The second name needs sanitising before it can key a file.
    pvent 'par/one@example.com' tk-par1 $(( NOWP + 3600 )) par1
    pvent par2@example.com tk-par2 $(( NOWP + 3600 ))
    cp "$PB/body.tk-ok" "$PB/body.tk-par1"
    printf '429' > "$PB/status.tk-par2"
    printf '%s\n' '{"type":"error","error":{"type":"rate_limit_error"}}' > "$PB/body.tk-par2"
    PAR=$(aprobe "printf '%s\n' '$VFP/par1.json' '$VFP/par2@example.com.json' | acct_probe_all" \
        SESSION_DATA_DIR="$PD" PATH="$PB:$PATH")
    report "$(printf 'par/one@example.com\tgood\t24\t48\t89\t%s\t%s\t%s\t1' "$CAP5" "$CAPW" "$CAPW")" \
        "$(printf '%s\n' "$PAR" | awk -F'\t' '$1 == "par/one@example.com"')" \
        "case 14 [probe]: a fan-out keeps each login's own answer, under a name that has to be sanitised before it can key a file"
    report "$(printf 'par2@example.com\t%s' "$(pnone unreachable)")" \
        "$(printf '%s\n' "$PAR" | awk -F'\t' '$1 == "par2@example.com"')" \
        "case 14 [probe]: ... and the login the endpoint throttled is unreachable in the same fan-out"
    report 2 "$(printf '%s\n' "$PAR" | grep -c .)" \
        "case 14 [probe]: ... two logins in, two rows out"
    report "" "$(cd "$PD" && ls -a | grep '^\.probe\.')" \
        "case 14 [probe]: ... and the fan-out's temp directory is gone once the parent has read it"
fi

echo "--- decide: session account auto ---"

if ! have jq || ! have perl; then
    skip "decide: session account auto" "needs jq and perl"
else
    # The decision verb end to end, in a fixture world: a live login with its own
    # credentials, a vault, and the curl stub answering the usage endpoint per
    # token. The clock is pinned with SESSION_NOW because the cooldown and the
    # probation window are the two things this verb decides on before it decides
    # anything else.
    DNOW=1790000000
    DEXP=$(( DNOW + 3600 ))
    DI1='2099-01-01T00:00:00+00:00'; DE1=4070908800
    DI2='2099-01-02T00:00:00+00:00'; DE2=4070995200
    DI3='2099-01-03T00:00:00+00:00'; DE3=4071081600
    DCLOCK=$DNOW
    DNOTIFY=""

    dvent() {  # WORLD LOGIN TOKEN [EXPIRES_MS] — a vault entry the screening accepts
        printf '{"email":"%s","login":"%s","oauthAccount":{"emailAddress":"%s"},"claudeAiOauth":{"accessToken":"%s","expiresAt":%s}}\n' \
            "$2" "$2" "$2" "$3" "${4:-${DEXP}000}" > "$1/vault/$2.json"
    }
    dlive() {  # WORLD LOGIN TOKEN — the identity and the credential actually serving requests
        mklogin "$1" "$2"
        printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":%s000},"mcpOAuth":{"granola":"keep-me"}}\n' \
            "$3" "$DEXP" > "$1/cfg/.credentials.json"
    }
    dbody() {  # STUB TOKEN FIVE WEEK FABLE [5h_ISO] [week_ISO] [fable_ISO]
        printf '{"limits":[{"kind":"session","percent":%s,"resets_at":"%s"},{"kind":"weekly_all","percent":%s,"resets_at":"%s"},{"kind":"weekly_scoped","percent":%s,"resets_at":"%s","scope":{"model":{"display_name":"Fable"}}}]}\n' \
            "$3" "${6:-$DI1}" "$4" "${7:-$DI1}" "$5" "${8:-$DI1}" > "$1/body.$2"
    }
    dworld() {  # -> a world with a vault directory beside its config dir and data root
        local w; w=$(world); mkdir -p "$w/vault"; printf '%s\n' "$w"
    }
    dauto() {  # WORLD STUB [args...] — one decision, stderr folded in
        local w="$1" c="$2"; shift 2
        sess "$w" PATH="$c:$PATH" SESSION_ACCOUNTS_DIR="$w/vault" \
            SESSION_NOW="$DCLOCK" SESSION_SWITCH_NOTIFY="$DNOTIFY" -- account auto "$@" 2>&1
    }
    dkv() {  # KEY OUTPUT -> the value of one k=v line
        printf '%s\n' "$2" | awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }'
    }
    ddet() {  # KEY LOGFILE [ROW] -> one key out of that row's detail bag
        awk -F'\t' -v k="$1" -v r="${3:-1}" 'NR == r {
            n = split($8, kv, ";")
            for (i = 1; i <= n; i++)
                if (index(kv[i], k "=") == 1) print substr(kv[i], length(k) + 2)
        }' "$2"
    }
    dasked() {  # STUB TOKEN... -> how many of those tokens reached the endpoint
        local d="$1" t n=0; shift
        for t in "$@"; do [ -e "$d/asked.$t" ] && n=$(( n + 1 )); done
        printf '%s\n' "$n"
    }
    dwait() {  # FILE LINES — the notify seam fires in the background, so poll for it
        local n=0
        while [ "$(grep -c . "$1" 2>/dev/null || echo 0)" -lt "$2" ] && [ "$n" -lt 25 ]; do
            sleep 0.2 2>/dev/null || sleep 1
            n=$(( n + 1 ))
        done
    }

    # ── a cap death on a login that serves nothing moves the box ──────────────
    WD1=$(dworld); CD1=$(curlstub); DLOG1="$WD1/data/switch-log.tsv"
    dlive "$WD1" a@example.com tok-a
    dvent "$WD1" a@example.com tok-a
    dvent "$WD1" b@example.com tok-b
    dbody "$CD1" tok-a 95 10 10     # live: its five-hour window is spent, so it serves nothing
    dbody "$CD1" tok-b 10 10 10     # a candidate clear on all three windows
    DNOTE1="$TMP/decide-notified"
    DNOTIFY="$TMP/decide-notify.sh"
    printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s"\n' "$DNOTE1" > "$DNOTIFY"; chmod 755 "$DNOTIFY"

    out=$(dauto "$WD1" "$CD1" --trigger cap --sid sid-1); rc=$?
    report 0 "$rc" "decide: a cap death on a spent login switches and exits 0"
    report switch "$(dkv ev "$out")" "decide: ... saying so on its own output channel"
    report 'a@example.com b@example.com 2' \
        "$(dkv from "$out") $(dkv to "$out") $(dkv tier "$out")" \
        "decide: ... naming both logins and the tier the box lands on"
    report tok-b "$(jq -r '.claudeAiOauth.accessToken' "$WD1/cfg/.credentials.json")" \
        "decide: ... having installed the candidate's credential"
    report keep-me "$(jq -r '.mcpOAuth.granola' "$WD1/cfg/.credentials.json")" \
        "decide: ... leaving mcpOAuth, which is not account-scoped, alone"
    report b@example.com "$(jq -r '.oauthAccount.emailAddress' "$WD1/cfg/.claude.json")" \
        "decide: ... and moved the identity with it"
    report 1 "$(grep -c . "$DLOG1")" "decide: one decision leaves exactly one audit row"
    report 'switch a@example.com b@example.com cap climbed' \
        "$(awk -F'\t' 'NR==1{print $2, $3, $4, $5, $6}' "$DLOG1")" \
        "decide: ... carrying the event, both logins, the trigger and the reason"
    report 'a@example.com=95/10/10*;b@example.com=10/10/10*' "$(awk -F'\t' 'NR==1{print $7}' "$DLOG1")" \
        "decide: ... every login's figures, the live one first, starred because they were probed"
    report 'sid-1 good 2' "$(ddet sid "$DLOG1") $(ddet http "$DLOG1") $(ddet tier "$DLOG1")" \
        "decide: ... the session that asked, the live probe's outcome and the landing tier"
    report sent "$(ddet notify "$DLOG1")" "decide: ... and that the notify seam was fired"
    report "" "$(ddet next_eligible "$DLOG1")" \
        "decide: a switch carries no next_eligible — it would overwrite a hold's real one for a reader"
    dwait "$DNOTE1" 1
    report 1 "$(grep -c . "$DNOTE1" 2>/dev/null || true)" "decide: the notify seam is called once on a switch"
    report yes "$(grep -q 'a@example.com' "$DNOTE1" && grep -q 'b@example.com' "$DNOTE1" && echo yes || echo no)" \
        "decide: ... naming the login it left and the one it moved to"
    report 0 "$(grep -c 'tok-' "$DLOG1" || true)" "decide: no token value reaches the audit log"
    report "" "$(cd "$WD1/data" && ls -a | grep -E '^\.(probe|ident|dry)\.' || true)" \
        "decide: ... and no scratch directory is left in the data root"

    # A switch that has just happened is still being judged: while its target is
    # the login now live, the next death re-decides instead of waiting out the
    # cooldown. That is the only way back for a switch that did not land.
    DCLOCK=$(( DNOW + 60 ))
    out=$(dauto "$WD1" "$CD1" --trigger cap --sid sid-2); rc=$?
    report 3 "$rc" "decide: a second death inside probation is not held on the cooldown"
    report 'hold live-clean' "$(dkv ev "$out") $(dkv reason "$out")" \
        "decide: ... it re-decides, and holds because the login it moved to is verified clean"
    report 2 "$(grep -c . "$DLOG1")" "decide: ... on its own audit row"
    report 1 "$(grep -c . "$DNOTE1" 2>/dev/null || true)" \
        "decide: a hold sends no notification — holds are the normal outcome"

    DCLOCK=$(( DNOW + ACCT_PROBATION_S + 1 ))
    out=$(dauto "$WD1" "$CD1" --trigger cap --sid sid-3); rc=$?
    report 3 "$rc" "decide: one second past the probation window the cooldown applies again"
    report 'hold cooldown' "$(dkv ev "$out") $(dkv reason "$out")" "decide: ... and says which gate held it"
    report 3 "$(grep -c . "$DLOG1")" "decide: ... recording that hold too"
    report "" "$(ddet tier "$DLOG1" 3)" "decide: ... with no tier and no figures, because it probed nothing"
    report tok-b "$(jq -r '.claudeAiOauth.accessToken' "$WD1/cfg/.credentials.json")" \
        "decide: ... and swapping nothing"

    DCLOCK=$(( DNOW + ACCT_COOLDOWN_S + 61 ))
    out=$(dauto "$WD1" "$CD1" --trigger cap --sid sid-4); rc=$?
    report 'hold live-clean' "$(dkv ev "$out") $(dkv reason "$out")" \
        "decide: a cooldown hold does not itself restart the cooldown, which would hold a retrying session for ever"

    # ── the three refusals, all of them before any state or any request ───────
    WD2=$(dworld); CD2=$(curlstub)
    dlive "$WD2" a@example.com tok-a
    dvent "$WD2" a@example.com tok-a; dvent "$WD2" b@example.com tok-b
    dbody "$CD2" tok-a 95 10 10; dbody "$CD2" tok-b 10 10 10
    DCLOCK=$DNOW; DNOTIFY=""
    dauto2() { sess "$WD2" PATH="$CD2:$PATH" SESSION_ACCOUNTS_DIR="$WD2/vault" \
                    SESSION_NOW="$DNOW" SESSION_AUTO_SWITCH="$1" -- account auto 2>&1; }

    out=$(dauto2 off); rc=$?
    report 4 "$rc" "decide: SESSION_AUTO_SWITCH=off refuses"
    report 'refuse off' "$(dkv ev "$out") $(dkv reason "$out")" "decide: ... naming the knob that turned it off"
    report absent "$([ -e "$WD2/data/switch-log.tsv" ] && echo present || echo absent)" \
        "decide: ... and writes nothing at all"
    report 0 "$(dasked "$CD2" tok-a tok-b)" "decide: ... having asked the endpoint nothing"

    out=$(dauto2 maybe); rc=$?
    report 4 "$rc" "decide: a switch mode that is neither on nor off refuses rather than guessing"
    report bad-mode "$(dkv reason "$out")" "decide: ... as a mode it cannot read"
    report yes "$(printf '%s' "$out" | grep -q 'on or off' && echo yes || echo no)" \
        "decide: ... saying which two values it takes, since this is the feature's kill switch"

    WD3=$(dworld); CD3=$(curlstub)
    mklogin "$WD3" a@example.com
    dvent "$WD3" a@example.com tok-a; dvent "$WD3" b@example.com tok-b
    out=$(dauto "$WD3" "$CD3"); rc=$?
    report 4 "$rc" "decide: the macOS shape, with no .credentials.json to swap, refuses"
    report yes "$(printf '%s' "$out" | grep -q Keychain && echo yes || echo no)" \
        "decide: ... naming the Keychain as the reason"
    report absent "$([ -e "$WD3/data/switch-log.tsv" ] && echo present || echo absent)" \
        "decide: ... and writes nothing"

    WD4=$(dworld); CD4=$(curlstub)
    dlive "$WD4" a@example.com tok-a; dvent "$WD4" a@example.com tok-a
    out=$(dauto "$WD4" "$CD4"); rc=$?
    report 4 "$rc" "decide: one vaulted login is nothing to switch to, so it refuses"
    report too-few-logins "$(dkv reason "$out")" "decide: ... saying so"
    report 0 "$(dasked "$CD4" tok-a)" "decide: ... before any request to the endpoint"

    # ── --dry-run: the same decision, with every write and the seam suppressed ─
    WD5=$(dworld); CD5=$(curlstub)
    dlive "$WD5" a@example.com tok-a
    dvent "$WD5" a@example.com tok-a; dvent "$WD5" b@example.com tok-b
    dbody "$CD5" tok-a 95 10 10; dbody "$CD5" tok-b 10 10 10
    DNOTE5="$TMP/decide-dry-notified"
    DNOTIFY="$TMP/decide-dry-notify.sh"
    printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s"\n' "$DNOTE5" > "$DNOTIFY"; chmod 755 "$DNOTIFY"
    DCLOCK=$DNOW
    out=$(dauto "$WD5" "$CD5" --dry-run --trigger manual); rc=$?
    report 3 "$rc" "decide: --dry-run exits 3, like any decision that moved nothing"
    report 'dry-run climbed b@example.com' \
        "$(dkv ev "$out") $(dkv reason "$out") $(dkv to "$out")" \
        "decide: ... naming the login it would have moved to and why"
    report yes "$(printf '%s\n' "$out" | grep -q '^cand=b@example.com/2/probe/10/10/10$' && echo yes || echo no)" \
        "decide: ... printing the ranked candidates it read"
    report yes "$(printf '%s\n' "$out" | grep -q '^live=a@example.com/0/probe/95/10/10$' && echo yes || echo no)" \
        "decide: ... beside the live login it compared them against"
    report tok-a "$(jq -r '.claudeAiOauth.accessToken' "$WD5/cfg/.credentials.json")" \
        "decide: ... and swapping nothing"
    report absent "$([ -e "$WD5/data/switch-log.tsv" ] && echo present || echo absent)" \
        "decide: ... writing no audit row"
    report "" "$(cd "$WD5/data" && ls | grep -E '^(fable|probe-body)\.' || true)" \
        "decide: ... and no cache file, although it probed both logins"
    report "" "$(cd "$WD5/data" && ls -a | grep -E '^\.(probe|ident|dry)\.' || true)" \
        "decide: ... nor any scratch left behind"
    report absent "$([ -s "$DNOTE5" ] && echo present || echo absent)" \
        "decide: ... and sends no notification"

    # ── next_eligible_at: when the earliest rejected candidate climbs ─────────
    WD6=$(dworld); CD6=$(curlstub); DLOG6="$WD6/data/switch-log.tsv"
    dlive "$WD6" a@example.com tok-a
    dvent "$WD6" a@example.com tok-a
    dvent "$WD6" b@example.com tok-b
    dvent "$WD6" c@example.com tok-c
    dbody "$CD6" tok-a 95 10 10 "$DI3" "$DI3" "$DI3"   # live: serves nothing
    dbody "$CD6" tok-b 10 95 10 "$DI1" "$DI2" "$DI1"   # held down by its weekly, which turns over on the 2nd
    dbody "$CD6" tok-c 95 10 10 "$DI3" "$DI1" "$DI1"   # held down by its five-hour, on the 3rd
    DCLOCK=$DNOW; DNOTIFY=""
    out=$(dauto "$WD6" "$CD6" --trigger cap); rc=$?
    report 3 "$rc" "decide: nothing standing above the live login's tier is a hold"
    report 'hold no-candidate' "$(dkv ev "$out") $(dkv reason "$out")" "decide: ... saying there was no candidate"
    report "$DE2" "$(dkv next_eligible_at "$out")" \
        "decide: next_eligible_at is the earliest reset that lifts any one rejected candidate above the live tier"
    report "$DE2" "$(ddet next_eligible "$DLOG6")" "decide: ... persisted on the hold row for a caller that got no output"
    report 0 "$(ddet tier "$DLOG6")" "decide: ... beside the tier the box is staying on"
    report yes "$(awk -F'\t' 'NR==1{print $7}' "$DLOG6" | grep -q 'c@example.com=95/10/10\*' && echo yes || echo no)" \
        "decide: ... and every candidate's figures, so the hold can be read back"

    # Only a probed candidate carries reset epochs at all: the frozen path
    # renders durations and drops Fable's reset outright.
    WD7=$(dworld); CD7=$(curlstub)
    dlive "$WD7" a@example.com tok-a
    dvent "$WD7" a@example.com tok-a
    dvent "$WD7" b@example.com tok-b $(( DNOW - 60 ))000
    dbody "$CD7" tok-a 95 10 10
    out=$(dauto "$WD7" "$CD7" --trigger cap); rc=$?
    report 'hold no-candidate -' "$(dkv ev "$out") $(dkv reason "$out") $(dkv next_eligible_at "$out")" \
        "decide: a candidate whose token lapsed contributes no reset, so next_eligible_at is unknown"
    report 0 "$(dasked "$CD7" tok-b)" "decide: ... and its lapsed token is never sent"

    # ── a switch onto a Fable-spent login is labelled, because it is partial ──
    WD8=$(dworld); CD8=$(curlstub); DLOG8="$WD8/data/switch-log.tsv"
    dlive "$WD8" a@example.com tok-a
    dvent "$WD8" a@example.com tok-a; dvent "$WD8" b@example.com tok-b
    dbody "$CD8" tok-a 95 10 10
    dbody "$CD8" tok-b 10 10 95     # serves every model except Fable
    out=$(dauto "$WD8" "$CD8" --trigger cap); rc=$?
    report 0 "$rc" "decide: a tier-0 live login moves onto a Fable-spent candidate"
    report 'switch b@example.com 1' "$(dkv ev "$out") $(dkv to "$out") $(dkv tier "$out")" \
        "decide: ... and the tier says the new login cannot serve Fable"
    report 1 "$(ddet tier "$DLOG8")" \
        "decide: ... on the audit row too, which is how the sessions woken by the config watch learn it"

    # ── degraded inputs: no curl, and a live login the endpoint will not answer ─
    WD9=$(dworld); DLOG9="$WD9/data/switch-log.tsv"
    DREAL=$(date +%s); DFUT=$(( DREAL + 36000 ))
    dlive "$WD9" a@example.com tok-a
    dvent "$WD9" a@example.com tok-a; dvent "$WD9" b@example.com tok-b
    mkcache "$WD9" a@example.com 95 10 "$DFUT" "$DFUT"
    mkcache "$WD9" b@example.com 10 10 "$DFUT" "$DFUT"
    printf '{"fable":{"used_percentage":10,"resets_at":%s}}\n' "$DFUT" > "$WD9/data/fable.a@example.com.json"
    printf '{"fable":{"used_percentage":10,"resets_at":%s}}\n' "$DFUT" > "$WD9/data/fable.b@example.com.json"
    out=$(sess "$WD9" PATH="$(minipath curl)" SESSION_ACCOUNTS_DIR="$WD9/vault" \
            SESSION_NOW="$DNOW" SESSION_SWITCH_NOTIFY="" -- account auto --trigger cap 2>&1); rc=$?
    report 0 "$rc" "decide: a host with no curl still reaches a decision, from the frozen figures"
    report 'switch b@example.com' "$(dkv ev "$out") $(dkv to "$out")" "decide: ... and takes it"
    report 'a@example.com=95/10/10;b@example.com=10/10/10' "$(awk -F'\t' 'NR==1{print $7}' "$DLOG9")" \
        "decide: ... with no star on any figure, because nothing was verified"
    report nocurl "$(ddet http "$DLOG9")" "decide: ... and the row says why"

    WD10=$(dworld); CD10=$(curlstub); DLOG10="$WD10/data/switch-log.tsv"
    dlive "$WD10" a@example.com tok-a
    dvent "$WD10" a@example.com tok-a; dvent "$WD10" b@example.com tok-b
    printf '500' > "$CD10/status.tok-a"
    printf '%s\n' '{"error":{"type":"overloaded_error"}}' > "$CD10/body.tok-a"
    dbody "$CD10" tok-b 10 10 10
    mkcache "$WD10" a@example.com 95 10 "$DFUT" "$DFUT"
    printf '{"fable":{"used_percentage":10,"resets_at":%s}}\n' "$DFUT" > "$WD10/data/fable.a@example.com.json"
    out=$(dauto "$WD10" "$CD10" --trigger cap); rc=$?
    report 0 "$rc" "decide: a live login the endpoint will not answer does not stop the decision"
    report unreachable "$(ddet http "$DLOG10")" \
        "decide: ... it is the network-down case, which is when the box most needs the other login"

    # ── a credential the endpoint rejects, on either side of the decision ────
    # The cache is not evidence about a token that has just been refused. On the
    # live side ignoring that is the whole authentication-failure case; on the
    # candidate side, ranking a rejected credential on its old figures is how a
    # dead one goes live.
    WD18=$(dworld); CD18=$(curlstub); DLOG18="$WD18/data/switch-log.tsv"
    dlive "$WD18" a@example.com tok-a
    dvent "$WD18" a@example.com tok-a; dvent "$WD18" b@example.com tok-b
    printf '401' > "$CD18/status.tok-a"
    printf '%s\n' '{"type":"error","error":{"type":"authentication_error","message":"OAuth access token is invalid."}}' > "$CD18/body.tok-a"
    dbody "$CD18" tok-b 10 10 95
    mkcache "$WD18" a@example.com 3 4 "$DFUT" "$DFUT"
    printf '{"fable":{"used_percentage":5,"resets_at":%s}}\n' "$DFUT" > "$WD18/data/fable.a@example.com.json"
    out=$(dauto "$WD18" "$CD18" --trigger auth); rc=$?
    report 0 "$rc" "decide: a live login the endpoint rejects serves nothing, whatever its cache says"
    report 'switch b@example.com' "$(dkv ev "$out") $(dkv to "$out")" \
        "decide: ... so even a Fable-spent candidate stands above it, which is the authentication outage this exists for"
    report 'dead a@example.com=-/-/-' "$(ddet http "$DLOG18") $(awk -F'\t' 'NR==1{split($7,f,";"); print f[1]}' "$DLOG18")" \
        "decide: ... and the row says the credential was refused rather than quoting the cache at it"

    WD19=$(dworld); CD19=$(curlstub)
    dlive "$WD19" a@example.com tok-a
    dvent "$WD19" a@example.com tok-a; dvent "$WD19" b@example.com tok-b
    dbody "$CD19" tok-a 95 10 10
    printf '401' > "$CD19/status.tok-b"
    printf '%s\n' '{"type":"error","error":{"type":"authentication_error","message":"OAuth access token is invalid."}}' > "$CD19/body.tok-b"
    mkcache "$WD19" b@example.com 1 2 "$DFUT" "$DFUT"
    printf '{"fable":{"used_percentage":3,"resets_at":%s}}\n' "$DFUT" > "$WD19/data/fable.b@example.com.json"
    out=$(dauto "$WD19" "$CD19" --trigger cap); rc=$?
    report 3 "$rc" "decide: a candidate the endpoint rejects is not promoted by its own cache"
    report 'hold no-candidate' "$(dkv ev "$out") $(dkv reason "$out")" \
        "decide: ... it ranks as unknown, which fails it closed, and the box stays put"
    report tok-a "$(jq -r '.claudeAiOauth.accessToken' "$WD19/cfg/.credentials.json")" \
        "decide: ... installing nothing"

    WD20=$(dworld); CD20=$(curlstub)
    dlive "$WD20" a@example.com tok-a
    dvent "$WD20" a@example.com tok-a; dvent "$WD20" b@example.com tok-b
    dbody "$CD20" tok-a 95 10 10; dbody "$CD20" tok-b 10 10 10
    out=$(dauto "$WD20" "$CD20" --trigger sideways); rc=$?
    report 5 "$rc" "decide: a trigger outside the log's closed enum is an error"
    report bad-trigger "$(dkv reason "$out")" "decide: ... named as one"
    report absent "$([ -e "$WD20/data/switch-log.tsv" ] && echo present || echo absent)" \
        "decide: ... and nothing is recorded under a word no reader knows"

    # ── the candidate screening, all three shapes, before any token is sent ───
    WD11=$(dworld); CD11=$(curlstub)
    dlive "$WD11" a@example.com tok-a
    dvent "$WD11" a@example.com tok-a
    dvent "$WD11" f@example.com tok-f
    printf '{"email":"b@example.com","login":"b@example.com","oauthAccount":{"emailAddress":"c@example.com"},"claudeAiOauth":{"accessToken":"tok-b","expiresAt":%s000}}\n' \
        "$DEXP" > "$WD11/vault/b@example.com.json"
    printf '{"email":"d@example.com","login":"d@example.com","oauthAccount":{"emailAddress":"d@example.com"},"claudeAiOauth":{"accessToken":"","expiresAt":%s000}}\n' \
        "$DEXP" > "$WD11/vault/d@example.com.json"
    printf '{"email":"e@example.com","login":"e@example.com","oauthAccount":{"emailAddress":"e@example.com"},"claudeAiOauth":{"accessToken":"tok-e","expiresAt":0}}\n' \
        > "$WD11/vault/e@example.com.json"
    dbody "$CD11" tok-a 95 10 10
    dbody "$CD11" tok-f 10 10 10
    out=$(dauto "$WD11" "$CD11" --trigger cap); rc=$?
    report 'switch f@example.com' "$(dkv ev "$out") $(dkv to "$out")" \
        "decide: the one vault entry that passes the credential predicate is the one it moves to"
    report 0 "$(dasked "$CD11" tok-b tok-e)" \
        "decide: ... and an entry filed under a name its own identity does not derive, or with no expiry, is never even asked"

    # ── the warn threshold, validated and clamped on this path ───────────────
    # `session account` dispatches before the CLI's own validation loop, so this
    # path carries the other half of it. Above 100 is the documented way to
    # silence the hook's advisory; without the clamp it would also mean "no
    # window is ever blocked" and quietly disable the switcher for anyone who
    # had quieted the hook.
    WD12=$(dworld); CD12=$(curlstub)
    dlive "$WD12" a@example.com tok-a
    dvent "$WD12" a@example.com tok-a; dvent "$WD12" b@example.com tok-b
    dbody "$CD12" tok-a 100 10 10; dbody "$CD12" tok-b 10 10 10
    out=$(sess "$WD12" PATH="$CD12:$PATH" SESSION_ACCOUNTS_DIR="$WD12/vault" SESSION_NOW="$DNOW" \
            SESSION_SWITCH_NOTIFY="" USAGE_WARN_PCT=150 -- account auto --trigger cap 2>&1); rc=$?
    report 0 "$rc" "decide: a warn threshold above 100 clamps rather than disabling the switcher"
    report 'switch b@example.com' "$(dkv ev "$out") $(dkv to "$out")" \
        "decide: ... so a login at 100% still reads as spent and the box moves"

    WD13=$(dworld); CD13=$(curlstub)
    dlive "$WD13" a@example.com tok-a
    dvent "$WD13" a@example.com tok-a; dvent "$WD13" b@example.com tok-b
    dbody "$CD13" tok-a 95 10 10; dbody "$CD13" tok-b 10 10 10
    out=$(sess "$WD13" PATH="$CD13:$PATH" SESSION_ACCOUNTS_DIR="$WD13/vault" SESSION_NOW="$DNOW" \
            SESSION_SWITCH_NOTIFY="" USAGE_WARN_PCT=ninety -- account auto --trigger cap 2>&1); rc=$?
    report 5 "$rc" "decide: a warn threshold that is not a number is an error here, not a threshold of nothing"
    report yes "$(printf '%s' "$out" | grep -q USAGE_WARN_PCT && echo yes || echo no)" \
        "decide: ... naming the variable to fix"
    report absent "$([ -e "$WD13/data/switch-log.tsv" ] && echo present || echo absent)" \
        "decide: ... and deciding nothing"
    report tok-a "$(jq -r '.claudeAiOauth.accessToken' "$WD13/cfg/.credentials.json")" \
        "decide: ... having swapped nothing"

    # ── a swap that reports success and lands something else ─────────────────
    WD14=$(dworld); CD14=$(curlstub); DLOG14="$WD14/data/switch-log.tsv"
    dlive "$WD14" a@example.com tok-a
    dvent "$WD14" a@example.com tok-a; dvent "$WD14" b@example.com tok-b
    dbody "$CD14" tok-a 95 10 10; dbody "$CD14" tok-b 10 10 10
    DTJ=$(mktemp -d "$TMP/decide-tamperjq.XXXXXX")
    { printf '#!/usr/bin/env bash\nRJQ=%s\n' "$(command -v jq)"
      cat <<'DTAMPEREOF'
args=()
for x in "$@"; do
    [ "$x" = '.claudeAiOauth = $v[0].claudeAiOauth' ] && \
        x='.claudeAiOauth = ($v[0].claudeAiOauth | .accessToken = "tok-tampered")'
    args+=("$x")
done
exec "$RJQ" "${args[@]}"
DTAMPEREOF
    } > "$DTJ/jq"
    chmod +x "$DTJ/jq"
    out=$(dauto "$WD14" "$DTJ:$CD14" --trigger cap --sid sid-f); rc=$?
    report 5 "$rc" "decide: a swap whose post-condition fails is an error, not a switch"
    report 'fail swap-not-observed' "$(dkv ev "$out") $(dkv reason "$out")" "decide: ... recorded as what it is"
    report 1 "$(grep -c . "$DLOG14")" "decide: ... on exactly one audit row, like any other decision"
    report 'fail a@example.com b@example.com' "$(awk -F'\t' 'NR==1{print $2, $3, $4}' "$DLOG14")" \
        "decide: ... whose from is the login it started on, never the identity file the failed swap already rewrote"
    report b@example.com "$(jq -r '.oauthAccount.emailAddress' "$WD14/cfg/.claude.json")" \
        "decide: ... which by then names the incoming login, and is the witness that lies"
    report "" "$(ddet notify "$DLOG14")" "decide: ... and nothing is announced, because nothing moved"

    # ── one decision at a time, box-wide ─────────────────────────────────────
    # The two locking backends report busy with their own code — 1 from flock(1),
    # 75 from the perl fallback — so neither may collide with a decision, which
    # is why this verb never returns 1 itself.
    WD15=$(dworld); CD15=$(curlstub)
    dlive "$WD15" a@example.com tok-a
    dvent "$WD15" a@example.com tok-a; dvent "$WD15" b@example.com tok-b
    dbody "$CD15" tok-a 95 10 10; dbody "$CD15" tok-b 10 10 10
    lock_run "$WD15/data/switch.lock" sleep 3 &
    dlkpid=$!
    sleep 0.5
    out=$(dauto "$WD15" "$CD15" --trigger cap); rc=$?
    report yes "$( { [ "$rc" = 1 ] || [ "$rc" = 75 ]; } && echo yes || echo no)" \
        "decide: a decision already in flight makes the next caller busy, never a second decision"
    report absent "$([ -e "$WD15/data/switch-log.tsv" ] && echo present || echo absent)" \
        "decide: ... which writes no row"
    report tok-a "$(jq -r '.claudeAiOauth.accessToken' "$WD15/cfg/.credentials.json")" \
        "decide: ... and swaps nothing"
    wait "$dlkpid" 2>/dev/null
    out=$(dauto "$WD15" "$CD15" --trigger cap); rc=$?
    report 0 "$rc" "decide: ... while the same call decides normally once the lock is free"

    WD16=$(dworld); DLOG16="$WD16/data/switch-log.tsv"
    CD16=$(curlstub)
    dlive "$WD16" a@example.com tok-a
    dvent "$WD16" a@example.com tok-a; dvent "$WD16" b@example.com tok-b
    dbody "$CD16" tok-a 95 10 10; dbody "$CD16" tok-b 10 10 10
    mv "$CD16/curl" "$CD16/curl.real"
    printf '#!/bin/sh\nsleep 2\nexec "%s/curl.real" "$@"\n' "$CD16" > "$CD16/curl"
    chmod +x "$CD16/curl"
    for i in 1 2 3; do
        ( dauto "$WD16" "$CD16" --trigger cap > "$TMP/decide-race.$i" 2>&1; echo $? > "$TMP/decide-race.rc.$i" ) &
    done
    wait
    report 1 "$(awk -F'\t' '$2 == "switch"' "$DLOG16" | grep -c . || true)" \
        "decide: three simultaneous decisions produce exactly one switch"
    report 1 "$(cat "$TMP/decide-race.rc.1" "$TMP/decide-race.rc.2" "$TMP/decide-race.rc.3" | grep -c '^0$' || true)" \
        "decide: ... exactly one of the three reports it"
    report 'tok-b b@example.com' \
        "$(jq -r '.claudeAiOauth.accessToken' "$WD16/cfg/.credentials.json") $(jq -r '.oauthAccount.emailAddress' "$WD16/cfg/.claude.json")" \
        "decide: ... and the credential and the identity name the same login"

    # ── the notifier is fired after the locked section, never inside it ───────
    # lock_run EXECS its command, so the command and anything it backgrounds
    # inherit the lock descriptor and hold the lock for as long as they live —
    # measured on both backends, and not releasable from inside.
    WD17=$(dworld); CD17=$(curlstub)
    dlive "$WD17" a@example.com tok-a
    dvent "$WD17" a@example.com tok-a; dvent "$WD17" b@example.com tok-b
    dbody "$CD17" tok-a 95 10 10; dbody "$CD17" tok-b 10 10 10
    DNOTIFY="$TMP/decide-hang.sh"
    printf '#!/bin/sh\nsleep 30\n' > "$DNOTIFY"; chmod 755 "$DNOTIFY"
    dt0=$(date +%s)
    out=$(dauto "$WD17" "$CD17" --trigger cap); rc=$?
    dt1=$(date +%s)
    report 0 "$rc" "decide: a notifier that never returns does not change the decision"
    report yes "$([ $(( dt1 - dt0 )) -lt 15 ] && echo yes || echo no)" "decide: ... nor delay it"
    report 0 "$(lock_run "$WD17/data/switch.lock" true >/dev/null 2>&1; echo $?)" \
        "decide: ... nor hold the decision lock, which it would inherit if it were fired inside it"
    DNOTIFY=""

    # ── a data root that cannot hold the lock ─────────────────────────────────
    # The lock file lives under the data root, so lock_run opening it is what
    # fails first — 66 on both backends, which carries no event, no reason and
    # no row for a caller to act on. The hold below is the decision outcome that
    # does.
    WD21=$(dworld); CD21=$(curlstub)
    dlive "$WD21" a@example.com tok-a
    dvent "$WD21" a@example.com tok-a; dvent "$WD21" b@example.com tok-b
    dbody "$CD21" tok-a 95 10 10; dbody "$CD21" tok-b 10 10 10
    if [ "$(id -u)" = 0 ]; then
        skip "decide: an unwritable data root" "running as root, which writes anyway"
    else
        chmod 500 "$WD21/data"
        out=$(dauto "$WD21" "$CD21" --trigger cap); rc=$?
        chmod 700 "$WD21/data"
        report 3 "$rc" "decide: a data root it cannot write holds, and never wears a busy code"
        report 'hold not-writable' "$(dkv ev "$out") $(dkv reason "$out")" \
            "decide: ... saying no state means no switch"
        report tok-a "$(jq -r '.claudeAiOauth.accessToken' "$WD21/cfg/.credentials.json")" \
            "decide: ... and swapping nothing"
        report "" "$(printf '%s\n' "$out" | grep -v '^[a-z_]*=' || true)" \
            "decide: ... with nothing but k=v lines, no lock tool's error among them"
    fi

    # ── a credentials write that fails outright ──────────────────────────────
    WD22=$(dworld); CD22=$(curlstub); DLOG22="$WD22/data/switch-log.tsv"
    dlive "$WD22" a@example.com tok-a
    dvent "$WD22" a@example.com tok-a; dvent "$WD22" b@example.com tok-b
    dbody "$CD22" tok-a 95 10 10; dbody "$CD22" tok-b 10 10 10
    DFJ=$(mktemp -d "$TMP/decide-failjq.XXXXXX")
    { printf '#!/usr/bin/env bash\nRJQ=%s\n' "$(command -v jq)"
      cat <<'DFAILEOF'
for x in "$@"; do
    [ "$x" = '.claudeAiOauth = $v[0].claudeAiOauth' ] && exit 5
done
exec "$RJQ" "$@"
DFAILEOF
    } > "$DFJ/jq"
    chmod +x "$DFJ/jq"
    cp "$WD22/cfg/.claude.json" "$TMP/decide-claude-before"
    out=$(dauto "$WD22" "$DFJ:$CD22" --trigger cap); rc=$?
    report 5 "$rc" "decide: a credentials write that fails is an error"
    report 'fail swap-write-failed' "$(dkv ev "$out") $(dkv reason "$out")" \
        "decide: ... named as the write, which is not the same failure as a swap that did not land"
    report 1 "$(grep -c . "$DLOG22")" "decide: ... on one audit row like any other decision"
    report tok-a "$(jq -r '.claudeAiOauth.accessToken' "$WD22/cfg/.credentials.json")" \
        "decide: ... with the live credential untouched"
    report yes "$(cmp -s "$TMP/decide-claude-before" "$WD22/cfg/.claude.json" && echo yes || echo no)" \
        "decide: ... and the identity file never written, which is why this failure gets no probation"

    # ── next_eligible_at when the live login lacks only Fable ────────────────
    # A candidate then has to clear all three windows to stand above it, so a
    # Fable reset is what promotes one — the window a tier-0 live login's
    # arithmetic ignores.
    WD23=$(dworld); CD23=$(curlstub)
    dlive "$WD23" a@example.com tok-a
    dvent "$WD23" a@example.com tok-a
    dvent "$WD23" b@example.com tok-b
    dvent "$WD23" c@example.com tok-c
    dbody "$CD23" tok-a 10 10 95                          # live: every model but Fable
    dbody "$CD23" tok-b 10 10 95 "$DI1" "$DI1" "$DI2"     # same rung; its Fable turns over on the 2nd
    dbody "$CD23" tok-c 95 10 10 "$DI3" "$DI1" "$DI1"     # a rung below; its five-hour on the 3rd
    out=$(dauto "$WD23" "$CD23" --trigger cap); rc=$?
    report 'hold no-candidate' "$(dkv ev "$out") $(dkv reason "$out")" \
        "decide: a live login blocked only on Fable is not beaten by another on the same rung"
    report 1 "$(dkv tier "$out")" "decide: ... and the box stays on the tier it had"
    report "$DE2" "$(dkv next_eligible_at "$out")" \
        "decide: ... with next_eligible_at taken from the Fable reset that would promote one of them"

    # ── the threshold is read as decimal, not as octal ───────────────────────
    # A leading zero is what a human writes; `$(( 070 ))` is 56, and a switcher
    # gating at 56% instead of 70% would move the box on windows nobody called spent.
    WD24=$(dworld); CD24=$(curlstub)
    dlive "$WD24" a@example.com tok-a
    dvent "$WD24" a@example.com tok-a; dvent "$WD24" b@example.com tok-b
    dbody "$CD24" tok-a 60 10 10; dbody "$CD24" tok-b 10 10 10
    out=$(sess "$WD24" PATH="$CD24:$PATH" SESSION_ACCOUNTS_DIR="$WD24/vault" SESSION_NOW="$DNOW" \
            SESSION_SWITCH_NOTIFY="" USAGE_WARN_PCT=070 -- account auto --trigger cap 2>&1); rc=$?
    report 3 "$rc" "decide: a threshold written 070 gates at 70, so a live login at 60% is not spent"
    report 'hold live-clean' "$(dkv ev "$out") $(dkv reason "$out")" \
        "decide: ... and the box holds rather than moving on an octal reading of it"

    # ── an option the verb does not have ─────────────────────────────────────
    WD25=$(dworld); CD25=$(curlstub)
    dlive "$WD25" a@example.com tok-a
    dvent "$WD25" a@example.com tok-a; dvent "$WD25" b@example.com tok-b
    out=$(dauto "$WD25" "$CD25" --sideways); rc=$?
    report 5 "$rc" "decide: an option the verb does not have is an error, never a busy code"
    report bad-option "$(dkv reason "$out")" "decide: ... named as one"
    report absent "$([ -e "$WD25/data/switch-log.tsv" ] && echo present || echo absent)" \
        "decide: ... and nothing is decided on it"
fi

echo "--- arm: a cap death decides before the waiter sleeps ---"

if ! have jq || ! have perl; then
    skip "arm: the armed trigger" "needs jq and perl"
else
    # Two fixtures layered: the decision verb's world (a live credential, a vault
    # and a curl answering the usage endpoint per token) under the waiter's
    # simulated clock, so a reset hours out is reached in no real time.
    #
    # The clock base is PINNED TO THE ISO STAMPS the stub renders, because
    # next_eligible_at comes out of the probe's own reset stamps and the only
    # observable that says which target the waiter slept to is how far it slept.
    AI1='2099-01-01T00:00:00+00:00'                  # behind the base, by a day
    AI2='2099-01-02T00:00:00+00:00'; AE2=4070995200  # the base plus 1200 s
    AISOON='2099-01-01T23:50:00+00:00'               # the base plus 600 s
    AILATE='2099-01-02T01:53:20+00:00'               # the base plus 8000 s
    ABASE=$(( AE2 - 1200 ))
    AEXP=$(( ABASE + 86400 ))   # every fixture token outlives the simulated now
    ANOW=""                     # empty: the decision reads the simulated clock too

    # `sleep` records a tick instead of sleeping and `date +%s` reports 400 s per
    # tick — one step wider than the waiter's 300 s chunk, so every chunk lands
    # past its own end. Only the bare `date +%s` is intercepted: the probe's
    # `date -d ... +%s` has to reach the real one.
    AB=$(mktemp -d "$TMP/armbin.XXXXXX")
    AREALDATE=$(command -v date)
    AREALSLEEP=$(command -v sleep)
    cat > "$AB/sleep" <<ATICKEOF
#!/bin/sh
echo tick >> "$AB/ticks"
exit 0
ATICKEOF
    cat > "$AB/inotifywait" <<'AINOEOF'
#!/bin/sh
exit 0
AINOEOF
    cat > "$AB/date" <<ACLKEOF
#!/bin/sh
case "\$*" in
  '+%s') n=\$(grep -c . "$AB/ticks" 2>/dev/null)
         echo \$(( $ABASE + \${n:-0} * 400 )) ;;
  *)     exec "$AREALDATE" "\$@" ;;
esac
ACLKEOF
    chmod +x "$AB/sleep" "$AB/inotifywait" "$AB/date"

    # The waiter fails closed without a claude ancestor, so reaching the arming
    # arm at all needs one. Same shape as case 17's, kept local so this block
    # stands on its own.
    cat > "$TMP/arm-asclaude.sh" <<'AASEOF'
b=$1; shift
timeout 60 bash "$b" "$@"
AASEOF

    aworld() { local w; w=$(world); mkdir -p "$w/vault"; printf '%s\n' "$w"; }
    aent() {  # WORLD LOGIN TOKEN — a vault entry the candidate screening accepts
        printf '{"email":"%s","login":"%s","oauthAccount":{"emailAddress":"%s"},"claudeAiOauth":{"accessToken":"%s","expiresAt":%s000}}\n' \
            "$2" "$2" "$2" "$3" "$AEXP" > "$1/vault/$2.json"
    }
    alive() {  # WORLD LOGIN TOKEN — the identity and the credential serving requests
        mklogin "$1" "$2"
        printf '{"claudeAiOauth":{"accessToken":"%s","expiresAt":%s000}}\n' "$3" "$AEXP" \
            > "$1/cfg/.credentials.json"
    }
    adead() {  # STUB TOKEN — a credential the endpoint refuses
        printf '401' > "$1/status.$2"
        printf '%s\n' '{"type":"error","error":{"type":"authentication_error"}}' > "$1/body.$2"
    }
    abody() {  # STUB TOKEN FIVE WEEK FABLE [5h_ISO] [week_ISO] [fable_ISO]
        printf '{"limits":[{"kind":"session","percent":%s,"resets_at":"%s"},{"kind":"weekly_all","percent":%s,"resets_at":"%s"},{"kind":"weekly_scoped","percent":%s,"resets_at":"%s","scope":{"model":{"display_name":"Fable"}}}]}\n' \
            "$3" "${6:-$AI1}" "$4" "${7:-$AI1}" "$5" "${8:-$AI1}" > "$1/body.$2"
    }
    ARMERR="$TMP/arm.err"
    aspawn() {  # WORLD STUB ERROR_TYPE SID — one waiter, its status returned
        printf '{"session_id":"%s","hook_event_name":"StopFailure","error_type":"%s"}' "$4" "$3" \
        | env -i PATH="$AB:$2:$PATH" HOME="$FH" TZ=UTC \
              CLAUDE_CONFIG_DIR="$1/cfg" SESSION_DATA_DIR="$1/data" \
              SESSION_ACCOUNTS_DIR="$1/vault" SESSION_SWITCH_NOTIFY="" SESSION_NOW="$ANOW" \
              CLAUDE_CODE_SESSION_ID="$4" \
              bash -c 'exec -a claude bash "$@"' _ "$TMP/arm-asclaude.sh" "$BIN" --rewake-waiter \
              >/dev/null
    }
    # The waiter's exit code IS the wake-up, so the status is returned and the
    # wake-up text goes to a file a `$(...)` capture could not hand back.
    arun() {  # WORLD STUB ERROR_TYPE — from a fresh tick count and no waiter
        : > "$AB/ticks"
        rm -f "$1/data/sessions/$UUID.rewaiter"
        aspawn "$1" "$2" "$3" "$UUID" 2>"$ARMERR"
    }
    asaid() { grep -q "$1" "$ARMERR" && echo yes || echo no; }
    aticks() { grep -c . "$AB/ticks"; }
    arows() { grep -c . "$1/data/switch-log.tsv" 2>/dev/null || echo 0; }
    aswitches() { awk -F'\t' '$2 == "switch"' "$1/data/switch-log.tsv" 2>/dev/null | grep -c . || true; }
    atok() { jq -r '.claudeAiOauth.accessToken' "$1/cfg/.credentials.json"; }

    # ── a cap death the box can answer by moving ──────────────────────────────
    WA1=$(aworld); CA1=$(curlstub)
    alive "$WA1" a@example.com tok-a
    aent "$WA1" a@example.com tok-a
    aent "$WA1" b@example.com tok-b
    abody "$CA1" tok-a 95 10 10     # live: its five-hour window is spent
    abody "$CA1" tok-b 10 10 10     # a candidate clear on all three windows
    mkcache "$WA1" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA1" "$CA1" rate_limit; rc=$?
    report 2 "$rc" "arm: a cap death a login switch can answer wakes the session instead of parking it"
    report yes "$(asaid 'login switched (a@example.com → b@example.com)')" \
        "arm: ... naming the login it left and the one it moved to, from the decision's own output"
    report tok-b "$(atok "$WA1")" "arm: ... having installed the candidate's credential"
    report 0 "$(aticks)" "arm: ... and never slept, because the cap it would have slept out no longer applies"
    report 1 "$(aswitches "$WA1")" "arm: ... on exactly one switch row"
    report absent "$([ -e "$WA1/data/sessions/$UUID.rewaiter" ] && echo present || echo absent)" \
        "arm: ... leaving no waiter behind"

    # ── the wake comes after the pidfile dedup, the decision before it ────────
    # A session whose waiter already sleeps must still be able to rescue the box,
    # and must not then receive a second wake for the one switch: the sleeping
    # owner is woken by the config-directory watch instead.
    WA2=$(aworld); CA2=$(curlstub)
    alive "$WA2" a@example.com tok-a
    aent "$WA2" a@example.com tok-a; aent "$WA2" b@example.com tok-b
    abody "$CA2" tok-a 95 10 10; abody "$CA2" tok-b 10 10 10
    mkcache "$WA2" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    bash -c "exec -a rewake-waiter bash -c 'sleep 30; :'" &
    AOWNER=$!
    sleep 1
    printf '%s\n' "$AOWNER" > "$WA2/data/sessions/$UUID.rewaiter"
    : > "$AB/ticks"
    aspawn "$WA2" "$CA2" rate_limit "$UUID" 2>"$ARMERR"; rc=$?
    report 0 "$rc" "arm: a spawn whose session already owns a waiter delivers no second wake"
    report 1 "$(aswitches "$WA2")" "arm: ... although it reached the decision, which is what rescues the box"
    report tok-b "$(atok "$WA2")" "arm: ... and the switch happened"
    report "$AOWNER" "$(cat "$WA2/data/sessions/$UUID.rewaiter")" "arm: ... leaving the owner's pidfile alone"
    kill "$AOWNER" 2>/dev/null; wait "$AOWNER" 2>/dev/null

    # ── an authentication death decides too, on the ordinary cooldown ─────────
    # One interactive authentication failure with no recent switch to be in
    # probation from, five minutes after a blank credential write, is what a
    # ten-and-a-half-hour outage looked like.
    WA3=$(aworld); CA3=$(curlstub)
    alive "$WA3" a@example.com tok-a
    aent "$WA3" a@example.com tok-a; aent "$WA3" b@example.com tok-b
    adead "$CA3" tok-a
    abody "$CA3" tok-b 10 10 10
    mkcache "$WA3" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA3" "$CA3" authentication_failed; rc=$?
    report 2 "$rc" "arm: an authentication death with no recent switch behind it still reaches a decision"
    report yes "$(asaid 'login switched')" "arm: ... and the switch it takes is the wake-up"
    report 'switch auth' "$(awk -F'\t' 'NR==1{print $2, $5}' "$WA3/data/switch-log.tsv")" \
        "arm: ... recorded under the trigger that asked for it"

    # Past probation, inside the cooldown: the gate that bounds an authentication
    # storm to about one decision a quarter hour. The cache is keyed by the LIVE
    # login, so the statusline's first render under the new one is what puts the
    # waiter back above its reachability ceiling.
    mkcache "$WA3" b@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    ANOW=$(( ABASE + 700 ))
    arun "$WA3" "$CA3" authentication_failed; rc=$?
    ANOW=""
    report 0 "$rc" "arm: a second authentication death inside the cooldown wakes nobody"
    report 'hold cooldown' "$(awk -F'\t' 'NR==2{print $2, $6}' "$WA3/data/switch-log.tsv")" \
        "arm: ... it holds, which is what bounds an authentication storm"
    report tok-b "$(atok "$WA3")" "arm: ... and swaps nothing"

    # Every documented sibling of authentication_failed decides on the same gate.
    for aerr in oauth_org_not_allowed account_on_hold billing_error cloud_credential_error; do
        WAS=$(aworld); CAS=$(curlstub)
        alive "$WAS" a@example.com tok-a
        aent "$WAS" a@example.com tok-a; aent "$WAS" b@example.com tok-b
        adead "$CAS" tok-a; abody "$CAS" tok-b 10 10 10
        mkcache "$WAS" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
        arun "$WAS" "$CAS" "$aerr"; rc=$?
        report 2 "$rc" "arm: $aerr decides like any other authentication death"
        # The exit code alone cannot say WHICH arm it landed in: a sibling
        # misfiled into the cap arm would switch here too, and would park the
        # session on a reset that cannot lift it when no switch was available.
        report 'switch auth' "$(awk -F'\t' 'NR==1{print $2, $5}' "$WAS/data/switch-log.tsv")" \
            "arm: ... on the trigger the authentication family asks under"
    done

    # ── the ceiling above all of it, kept deliberately ───────────────────────
    # The waiter reads its windows out of the statusline cache for the live
    # login, and leaves at once when there is none. The decision sits BELOW that
    # exit: it needs no cache, but hoisting it would mean hoisting the stdin read
    # and the parent walk with it, and the only window it leaves open is the
    # render or two after a switch, which `session doctor` reports as pending.
    WA14=$(aworld); CA14=$(curlstub)
    alive "$WA14" a@example.com tok-a
    aent "$WA14" a@example.com tok-a; aent "$WA14" b@example.com tok-b
    abody "$CA14" tok-a 95 10 10; abody "$CA14" tok-b 10 10 10
    arun "$WA14" "$CA14" rate_limit; rc=$?
    report 0 "$rc" "arm: a cap death on a login whose statusline has never rendered reaches no decision"
    report 0 "$(arows "$WA14")" "arm: ... and writes no row, which is what doctor reports as pending"

    # ── a failure that is neither a cap nor an authentication death ───────────
    WA6=$(aworld); CA6=$(curlstub)
    alive "$WA6" a@example.com tok-a
    aent "$WA6" a@example.com tok-a; aent "$WA6" b@example.com tok-b
    abody "$CA6" tok-a 95 10 10; abody "$CA6" tok-b 10 10 10
    mkcache "$WA6" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA6" "$CA6" api_error; rc=$?
    report 0 "$rc" "arm: a failure that is neither a cap nor an authentication death decides nothing"
    report 0 "$(arows "$WA6")" "arm: ... writing no row"
    report tok-a "$(atok "$WA6")" "arm: ... and leaving the live login alone"

    # ── a busy lock: no retry, and no reading of somebody else's decision ─────
    # Busy is 1 under flock(1) and 75 under the perl fallback. Both legs of this
    # suite resolve lock_run to flock(1), so only the 1 is exercised here; the 75
    # is the macOS path and nothing on either leg reaches it.
    WA4=$(aworld); CA4=$(curlstub)
    alive "$WA4" a@example.com tok-a
    aent "$WA4" a@example.com tok-a; aent "$WA4" b@example.com tok-b
    abody "$CA4" tok-a 95 10 10; abody "$CA4" tok-b 10 10 10
    mkcache "$WA4" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    # A switch row fresh enough that an audit-log fallback would read it as this
    # decision's own. It is a PREVIOUS decision, and waking on it would tell the
    # session the box had just moved when nothing moved.
    printf '%s\tswitch\tx@example.com\ty@example.com\tcap\tclimbed\t-\tsid=-;tier=2\n' \
        "$ABASE" > "$WA4/data/switch-log.tsv"
    lock_run "$WA4/data/switch.lock" "$AREALSLEEP" 5 &
    ALK=$!
    sleep 1
    arun "$WA4" "$CA4" rate_limit; rc=$?
    report 2 "$rc" "arm: a decision already in flight leaves the waiter to sleep the cap out"
    report yes "$(asaid '5h rate-limit window has reset')" \
        "arm: ... waking on the reset it derived itself"
    report no "$(asaid 'login switched')" \
        "arm: ... never on an audit row describing a decision it did not just cause"
    report 10 "$(aticks)" "arm: ... having slept the whole way to the 5h reset"
    report 1 "$(arows "$WA4")" "arm: ... and taking no decision of its own"
    wait "$ALK" 2>/dev/null

    # ── the insertion point: above the exit that used to end it here ──────────
    WA5=$(aworld); CA5=$(curlstub)
    alive "$WA5" a@example.com tok-a
    aent "$WA5" a@example.com tok-a; aent "$WA5" b@example.com tok-b
    abody "$CA5" tok-a 95 10 10; abody "$CA5" tok-b 10 10 10
    mkcache "$WA5" a@example.com 10 10 $(( ABASE - 100 )) $(( ABASE - 50 ))
    arun "$WA5" "$CA5" rate_limit; rc=$?
    report 2 "$rc" "arm: a cap death with no future reset in the cache still reaches a decision"
    report yes "$(asaid 'login switched')" "arm: ... where the waiter used to exit without arming anything"
    report tok-b "$(atok "$WA5")" "arm: ... and the box moves"

    # ── a switch onto a Fable-spent login says what it bought ────────────────
    WA10=$(aworld); CA10=$(curlstub)
    alive "$WA10" a@example.com tok-a
    aent "$WA10" a@example.com tok-a; aent "$WA10" b@example.com tok-b
    abody "$CA10" tok-a 95 10 10
    abody "$CA10" tok-b 10 10 95     # serves every model except Fable
    mkcache "$WA10" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA10" "$CA10" rate_limit; rc=$?
    report 2 "$rc" "arm: a cap death answered by a Fable-spent login still wakes the session"
    report yes "$(asaid 'except Fable')" \
        "arm: ... told in one sentence that the new login cannot serve Fable"
    report no "$(asaid 'earlier cap no longer applies')" \
        "arm: ... and never told the earlier cap is gone, which for a Fable turn is false"

    # ── an early wake at next_eligible_at is not a reset wake ────────────────
    # The hold names the time its best rejected candidate climbs above the live
    # login. That shortens the sleep once; it does not become the target, and it
    # must never take the loop's own exit message.
    WA7=$(aworld); CA7=$(curlstub)
    alive "$WA7" a@example.com tok-a
    aent "$WA7" a@example.com tok-a; aent "$WA7" b@example.com tok-b
    abody "$CA7" tok-a 95 10 10
    abody "$CA7" tok-b 10 95 10 "$AI1" "$AI2" "$AI1"   # held down by its weekly, +1200 s
    mkcache "$WA7" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA7" "$CA7" rate_limit; rc=$?
    report 2 "$rc" "arm: a hold that names a time leaves the waiter armed on the reset it derived"
    report yes "$(asaid '5h rate-limit window has reset')" \
        "arm: ... and the wake-up still names the window that target came from"
    report no "$(asaid 'login switched')" "arm: ... which is not a switch"
    report 10 "$(aticks)" "arm: ... having slept the whole way to the 5h reset, through the early wake"
    report 2 "$(arows "$WA7")" "arm: ... re-deciding exactly once on the way"
    report "$(( ABASE + 1200 ))" "$(awk -F'\t' 'NR==2{print $1}' "$WA7/data/switch-log.tsv")" \
        "arm: ... at the time the first decision named, not at the reset"

    # The same shape where the re-decision can move: the early wake is then the
    # wake-up, at the named time rather than at the reset.
    WA8=$(aworld); CA8=$(curlstub)
    alive "$WA8" a@example.com tok-a
    aent "$WA8" a@example.com tok-a; aent "$WA8" b@example.com tok-b
    abody "$CA8" tok-a 95 10 10
    abody "$CA8" tok-b 10 10 10
    cp "$CA8/body.tok-b" "$CA8/next.tok-b"                 # what b's window becomes
    abody "$CA8" tok-b 10 95 10 "$AI1" "$AI2" "$AI1"       # and what it is now
    mv "$CA8/curl" "$CA8/curl.real"
    cat > "$CA8/curl" <<ATURNEOF
#!/bin/sh
"$CA8/curl.real" "\$@"
rc=\$?
# The candidate's weekly window turns over between the two decisions, which a
# body file can only do by being replaced once it has been served.
[ -f "$CA8/next.tok-b" ] && [ -f "$CA8/asked.tok-b" ] && mv "$CA8/next.tok-b" "$CA8/body.tok-b"
exit \$rc
ATURNEOF
    chmod +x "$CA8/curl"
    mkcache "$WA8" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA8" "$CA8" rate_limit; rc=$?
    report 2 "$rc" "arm: an early wake whose re-decision can move the box takes it"
    report yes "$(asaid 'login switched')" "arm: ... and says so rather than announcing a reset"
    report 3 "$(aticks)" "arm: ... having slept only to the time the first decision named"
    report tok-b "$(atok "$WA8")" "arm: ... with the candidate's credential installed"

    # ── min(target, -) and min(target, a stale epoch) are both the target ─────
    WA9=$(aworld); CA9=$(curlstub)
    alive "$WA9" a@example.com tok-a
    aent "$WA9" a@example.com tok-a; aent "$WA9" b@example.com tok-b
    abody "$CA9" tok-a 95 10 10
    adead "$CA9" tok-b               # a rejected candidate carries no reset at all
    mkcache "$WA9" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA9" "$CA9" rate_limit; rc=$?
    report 2 "$rc" "arm: a hold that names no time at all still wakes on the reset"
    report 10 "$(aticks)" "arm: ... an unknown next_eligible_at never shortens the sleep"
    report 1 "$(arows "$WA9")" "arm: ... and nothing re-decides on the way"

    # A reset that has passed while the percentage behind it has not yet dropped:
    # the epoch is real and already behind, and arming on it would wake the
    # session straight back into the cap it is sleeping out.
    WA13=$(aworld); CA13=$(curlstub)
    alive "$WA13" a@example.com tok-a
    aent "$WA13" a@example.com tok-a; aent "$WA13" b@example.com tok-b
    abody "$CA13" tok-a 95 10 10
    abody "$CA13" tok-b 10 95 10 "$AI1" "$AI1" "$AI1"   # held down by a weekly that reset a day ago
    mkcache "$WA13" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA13" "$CA13" rate_limit; rc=$?
    report 2 "$rc" "arm: a next_eligible_at already in the past wakes nothing early"
    report 10 "$(aticks)" "arm: ... the sleep runs to the reset, as if no time had been named"
    report 1 "$(arows "$WA13")" "arm: ... and nothing re-decides on the way"

    # Inside the cooldown, where a re-decision could only hold on it again.
    WA15=$(aworld); CA15=$(curlstub)
    alive "$WA15" a@example.com tok-a
    aent "$WA15" a@example.com tok-a; aent "$WA15" b@example.com tok-b
    abody "$CA15" tok-a 95 10 10
    abody "$CA15" tok-b 10 95 10 "$AI1" "$AISOON" "$AI1"   # its weekly turns over in 600 s
    mkcache "$WA15" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA15" "$CA15" rate_limit; rc=$?
    report 2 "$rc" "arm: a next_eligible_at inside the cooldown wakes nothing early"
    report 10 "$(aticks)" "arm: ... because the decision it would wake for cannot be taken yet"
    report 1 "$(arows "$WA15")" "arm: ... so nothing re-decides on the way"

    # Beyond the reset, which is the ordinary shape: a candidate held down by its
    # WEEKLY window names a time days out while the live login's five-hour target
    # is hours out. The named time may only ever shorten a sleep.
    WA16=$(aworld); CA16=$(curlstub)
    alive "$WA16" a@example.com tok-a
    aent "$WA16" a@example.com tok-a; aent "$WA16" b@example.com tok-b
    abody "$CA16" tok-a 95 10 10
    abody "$CA16" tok-b 10 95 10 "$AI1" "$AILATE" "$AI1"   # its weekly turns over past the reset
    mkcache "$WA16" a@example.com 10 10 $(( ABASE + 4000 )) $(( ABASE + 5000 ))
    arun "$WA16" "$CA16" rate_limit; rc=$?
    report 2 "$rc" "arm: a next_eligible_at past the reset does not lengthen the sleep"
    report yes "$(asaid '5h rate-limit window has reset')" \
        "arm: ... so the wake-up is not delivered hours after the window it names turned over"
    report 10 "$(aticks)" "arm: ... the sleep still ends at the 5h reset"
    report 1 "$(arows "$WA16")" "arm: ... and nothing re-decides on the way"

    # ── every spawn decides; the lock makes it one decision ──────────────────
    WA12=$(aworld); CA12=$(curlstub)
    alive "$WA12" a@example.com tok-a
    aent "$WA12" a@example.com tok-a; aent "$WA12" b@example.com tok-b
    abody "$CA12" tok-a 95 10 10; abody "$CA12" tok-b 10 10 10
    mv "$CA12/curl" "$CA12/curl.real"
    printf '#!/bin/sh\n%s 2\nexec "%s/curl.real" "$@"\n' "$AREALSLEEP" "$CA12" > "$CA12/curl"
    chmod +x "$CA12/curl"
    mkcache "$WA12" a@example.com 10 10 $(( ABASE - 100 )) $(( ABASE - 50 ))
    : > "$AB/ticks"
    for i in 1 2 3; do
        ( aspawn "$WA12" "$CA12" rate_limit "sid-$i" 2>/dev/null; echo $? > "$TMP/arm-race.rc.$i" ) &
    done
    wait
    report 1 "$(aswitches "$WA12")" "arm: three spawns racing one cap produce exactly one switch"
    report 1 "$(cat "$TMP/arm-race.rc.1" "$TMP/arm-race.rc.2" "$TMP/arm-race.rc.3" | grep -c '^2$' || true)" \
        "arm: ... and exactly one of them wakes its session"

    # ── the tier a waiter reads when it never saw the decision ───────────────
    # A waiter woken by the config-directory watch sees the files change and not
    # the decision behind them, so the landing tier comes off the audit row.
    if have inotifywait; then
        WA11=$(aworld)
        alive "$WA11" a@example.com tok-a
        aent "$WA11" a@example.com tok-a          # one entry: the decision refuses, the waiter just arms
        ANOWR=$(date +%s)
        mkcache "$WA11" a@example.com 95 10 $(( ANOWR + 3600 )) $(( ANOWR + 36000 ))
        ( printf '{"session_id":"%s","hook_event_name":"StopFailure","error_type":"rate_limit"}' "$UUID" \
          | env -i PATH="$PATH" HOME="$FH" TZ=UTC \
                CLAUDE_CONFIG_DIR="$WA11/cfg" SESSION_DATA_DIR="$WA11/data" \
                SESSION_ACCOUNTS_DIR="$WA11/vault" CLAUDE_CODE_SESSION_ID="$UUID" \
                bash -c 'exec -a claude bash "$@"' _ "$TMP/arm-asclaude.sh" "$BIN" --rewake-waiter \
                >/dev/null 2>"$WA11/err"; echo $? > "$WA11/rc" ) &
        AWPID=$!
        i=0
        while [ ! -e "$WA11/data/sessions/$UUID.rewaiter" ] && [ "$i" -lt 15 ]; do sleep 1; i=$(( i + 1 )); done
        report present "$([ -e "$WA11/data/sessions/$UUID.rewaiter" ] && echo present || echo absent)" \
            "arm: a decision that refuses leaves the waiter armed on its reset"
        printf '%s\tswitch\ta@example.com\tb@example.com\tcap\tclimbed\t-\tsid=-;tier=1;notify=off\n' \
            "$(date +%s)" >> "$WA11/data/switch-log.tsv"
        mklogin "$WA11" b@example.com
        i=0
        while [ ! -e "$WA11/rc" ] && [ "$i" -lt 25 ]; do sleep 1; i=$(( i + 1 )); done
        wait "$AWPID" 2>/dev/null
        report 2 "$(cat "$WA11/rc" 2>/dev/null)" "arm: a waiter woken by a switch it did not take exits 2"
        report yes "$(grep -q 'except Fable' "$WA11/err" && echo yes || echo no)" \
            "arm: ... reading the landing tier off the audit row, having never seen the decision"
    else
        skip "arm: the tier a waiter reads off the audit row" "no inotifywait"
    fi
fi

echo "--- doctor: the switcher, the warn threshold, and the vault's own identities ---"

if ! have jq; then
    skip "doctor: the switcher check" "needs jq"
else
    DCW=$(mktemp -d "$TMP/dcw.XXXXXX")            # a cwd carrying no project settings
    DCB=$(mktemp -d "$TMP/dcb.XXXXXX"); ln -sf "$BIN" "$DCB/session"
    # The doctor only asks whether curl EXISTS, never runs it — and the bash 3.2
    # image has no curl at all, so the stub is what makes the two legs agree.
    DCC=$(curlstub)

    ddoc() {  # WORLD [VAR=VAL ...] -> the whole report, stderr folded in
        local w=$1; shift
        local e=""
        while [ $# -gt 0 ]; do e="$e $1"; shift; done
        ( cd "$DCW" && env -i PATH="$DCC:$DCB:$PATH" HOME="$FH" TZ=UTC \
            CLAUDE_CONFIG_DIR="$w/cfg" SESSION_DATA_DIR="$w/data" \
            SESSION_ACCOUNTS_DIR="$w/vault" CLAUDE_CODE_SESSION_ID="$UUID" \
            $e timeout 60 bash "$BIN" doctor 2>&1 )
    }
    dcstate() {  # OUTPUT LABEL -> the state on that check's first line, empty if absent
        printf '%s' "$1" | awk -v l="$2" '
            { s = $1; $1 = ""; sub(/^ +/, "")
              if (index($0, l) == 1) { print s; exit } }'
    }
    dcsays() {  # OUTPUT LABEL TEXT -> yes when any line with that label carries it
        printf '%s' "$1" | awk -v l="$2" -v t="$3" '
            { $1 = ""; sub(/^ +/, "")
              if (index($0, l) == 1 && index($0, t) > 0) found = 1 }
            END { if (found) print "yes"; else print "no" }'
    }
    dcvent() {  # WORLD LOGIN [TOKEN] — a vault entry filed under its own identity
        printf '{"email":"%s","login":"%s","oauthAccount":{"emailAddress":"%s"},"claudeAiOauth":{"accessToken":"%s","expiresAt":9999999999000}}\n' \
            "$2" "$2" "$2" "${3:-tok-$2}" > "$1/vault/$2.json"
    }
    dcarm() {  # WORLD both|prompt|unarmed|none — the rewake entries in settings.json
        local rw="bash $SDIR/session --rewake-waiter"
        case "$2" in
            both)    jq -n --arg rw "$rw" '{hooks: {UserPromptSubmit: [{hooks: [{type:"command", command:$rw, asyncRewake:true, timeout:700000}]}],
                                                    StopFailure:      [{hooks: [{type:"command", command:$rw, asyncRewake:true, timeout:700000}]}]}}' ;;
            prompt)  jq -n --arg rw "$rw" '{hooks: {UserPromptSubmit: [{hooks: [{type:"command", command:$rw, asyncRewake:true, timeout:700000}]}]}}' ;;
            unarmed) jq -n --arg rw "$rw" '{hooks: {StopFailure:      [{hooks: [{type:"command", command:$rw, timeout:700000}]}]}}' ;;
            none)    printf '{}\n' ;;
        esac > "$1/cfg/settings.json"
    }
    dcworld() {  # -> a world in which every state the switcher reads is healthy
        local w n
        w=$(world); mkdir -p "$w/vault"; chmod 700 "$w/data"; n=$(date +%s)
        mklogin "$w" a@example.com
        printf '{"claudeAiOauth":{"accessToken":"live-a","expiresAt":9999999999000}}\n' > "$w/cfg/.credentials.json"
        dcvent "$w" a@example.com; dcvent "$w" b@example.com
        dcarm "$w" both
        mkcache "$w" a@example.com 10 10 $(( n + 600 )) $(( n + 6000 ))
        # 601 and 301 seconds: acct_age floors at the minute, so the rendered
        # "10m" and "5m" survive any delay under 59s between here and the run.
        printf '%s\t%s\ts\tp1\t-\t-\n%s\t%s\tf\tp1\trate_limit\t-\n' \
            $(( n - 400 )) "$UUID" $(( n - 301 )) "$UUID" > "$w/data/turn-log.tsv"
        printf '%s\tswitch\ta@example.com\tb@example.com\tcap\tclimbed\t-\tsid=x;tier=2\n' \
            $(( n - 601 )) > "$w/data/switch-log.tsv"
        printf '%s\n' "$w"
    }

    # ── everything wired: the ok line carries the five facts a reader needs ──
    WDC=$(dcworld)
    DCOK=$(ddoc "$WDC"); rc=$?
    report 0 "$rc" "doctor: a switcher with everything it needs is not a failure"
    report ok "$(dcstate "$DCOK" switcher)" "doctor: ... and the switcher check reads ok"
    report yes "$(dcsays "$DCOK" switcher 'on ·')" "doctor: ... naming the mode it is in"
    report yes "$(dcsays "$DCOK" switcher 'notify none')" "doctor: ... the notify target"
    report yes "$(dcsays "$DCOK" switcher '2 logins, 2 with a token')" \
        "doctor: ... the vault's size beside how many of its entries carry a token at all"
    report yes "$(dcsays "$DCOK" switcher 'newest decision: switch (10m)')" \
        "doctor: ... and the newest decision with its age"
    report yes "$(dcsays "$DCOK" switcher 'newest cap death (5m)')" \
        "doctor: the newest cap death is printed beside it, so a switcher that runs and records nothing reads as a gap"

    # ── the notify seam ──────────────────────────────────────────────────────
    DCNOT="$TMP/dc-notify.sh"; printf '#!/bin/sh\nexit 0\n' > "$DCNOT"; chmod 755 "$DCNOT"
    out=$(ddoc "$WDC" SESSION_SWITCH_NOTIFY="$DCNOT")
    report yes "$(dcsays "$out" switcher "notify $DCNOT")" "doctor: an executable notify seam is named on the line"
    chmod 644 "$DCNOT"
    out=$(ddoc "$WDC" SESSION_SWITCH_NOTIFY="$DCNOT"); rc=$?
    report 1 "$rc" "doctor: a notify path that cannot be run is a failure"
    report FAIL "$(dcstate "$out" switcher)" \
        "doctor: ... because the switch would be taken and never announced"
    chmod 755 "$DCNOT"

    # ── the kill switch, and a value it cannot read ──────────────────────────
    out=$(ddoc "$WDC" SESSION_AUTO_SWITCH=off); rc=$?
    report 0 "$rc" "doctor: a switcher deliberately turned off is not a failure"
    report pending "$(dcstate "$out" switcher)" "doctor: ... it is pending"
    report yes "$(dcsays "$out" switcher SESSION_AUTO_SWITCH)" "doctor: ... naming the knob that turned it off"

    out=$(ddoc "$WDC" SESSION_AUTO_SWITCH=yes); rc=$?
    report 1 "$rc" "doctor: a mode the verb cannot read is a failure, not an absence"
    report FAIL "$(dcstate "$out" switcher)" "doctor: ... every decision would refuse on it"

    # ── the trigger's wiring, probed structurally rather than by grep ────────
    WDC2=$(dcworld); dcarm "$WDC2" prompt
    out=$(ddoc "$WDC2"); rc=$?
    report 1 "$rc" "doctor: an armed waiter on UserPromptSubmit alone carries no cap death to a decision"
    report FAIL "$(dcstate "$out" switcher)" "doctor: ... so the switcher check fails"
    report ok "$(dcstate "$out" auto-resume)" \
        "doctor: ... while auto-resume, which counts every event, still reads ok — the two ask different questions"

    WDC3=$(dcworld); dcarm "$WDC3" unarmed
    out=$(ddoc "$WDC3"); rc=$?
    report 1 "$rc" "doctor: a StopFailure entry without asyncRewake runs synchronously and wakes nobody"
    report FAIL "$(dcstate "$out" switcher)" \
        "doctor: ... and a grep for the command would have passed it, which is why the probe is structural"

    # ── the states that are pending rather than wrong ────────────────────────
    WDC4=$(dcworld); rm -f "$WDC4/cfg/.credentials.json"
    out=$(ddoc "$WDC4"); rc=$?
    report 0 "$rc" "doctor: a config dir with no credentials file is pending, not a failure"
    report pending "$(dcstate "$out" switcher)" "doctor: ... the shape a macOS Keychain install has, which this build cannot swap"
    report yes "$(dcsays "$out" switcher '.credentials.json')" "doctor: ... naming the file it looked for"

    WDC5=$(dcworld); rm -f "$WDC5/vault/b@example.com.json"
    out=$(ddoc "$WDC5"); rc=$?
    report 0 "$rc" "doctor: one vaulted login is pending — there is nowhere to switch to yet"
    report pending "$(dcstate "$out" switcher)" "doctor: ... rather than a failure"
    report yes "$(dcsays "$out" switcher '1 vaulted login')" "doctor: ... counting what the vault holds"

    WDC6=$(dcworld); rm -f "$WDC6/data/last-status.a@example.com.json"
    out=$(ddoc "$WDC6"); rc=$?
    report 0 "$rc" "doctor: a live login with no statusline cache is pending"
    report pending "$(dcstate "$out" switcher)" \
        "doctor: ... because the rewake path exits without one, before it reaches a decision"

    WDC7=$(dcworld)
    out=$(ddoc "$WDC7" PATH="$(minipath curl):$DCB"); rc=$?
    report 0 "$rc" "doctor: a host without curl still reaches a decision, on frozen figures"
    report pending "$(dcstate "$out" switcher)" "doctor: ... so it is pending, not a failure"
    report yes "$(dcsays "$out" switcher curl)" "doctor: ... naming what is missing"

    # ── a decision in flight ─────────────────────────────────────────────────
    WDC8=$(dcworld)
    ( lock_run "$WDC8/data/switch.lock" sleep 5 >/dev/null 2>&1 ) &
    dcpid=$!
    sleep 0.3 2>/dev/null || sleep 1
    out=$(ddoc "$WDC8")
    report yes "$(dcsays "$out" switcher 'lock not free')" "doctor: a decision in flight is visible on the lock"
    wait "$dcpid" 2>/dev/null
    out=$(ddoc "$WDC8")
    report no "$(dcsays "$out" switcher 'lock not free')" "doctor: ... and once it has finished the lock is free again"

    # ── the deferred guard, made visible ─────────────────────────────────────
    WDC9=$(dcworld); dcn=$(date +%s)
    { printf '%s\tswitch\ta@example.com\tb@example.com\tcap\tclimbed\t-\tsid=x;scoped=2\n' $(( dcn - 615 ))
      printf '%s\trefuse\tb@example.com\t-\tmanual\tblank-credential\t-\tnotify=off\n' $(( dcn - 60 ))
    } > "$WDC9/data/switch-log.tsv"
    out=$(ddoc "$WDC9"); rc=$?
    report 0 "$rc" "doctor: a second model-scoped weekly window is information, not a failure"
    report yes "$(dcsays "$out" switcher '2 model-scoped')" \
        "doctor: ... read from the newest row that CARRIES scoped=, which the refusal above it does not"
    report no "$(dcsays "$DCOK" switcher 'model-scoped')" \
        "doctor: a log whose newest row counted one window says nothing about it"

    WDC10=$(dcworld)
    printf '{"error":{"type":"rate_limit_error"}}\n' > "$WDC10/data/probe-body.b@example.com.json"
    out=$(ddoc "$WDC10"); rc=$?
    report 0 "$rc" "doctor: a usage response no window could be read from is reported, not failed on"
    report yes "$(dcsays "$out" switcher 'probe-body.b@example.com.json')" \
        "doctor: ... naming the file, because a good probe deletes it and its presence describes the LAST response"
    report no "$(dcsays "$DCOK" switcher 'probe-body')" "doctor: ... and says nothing when no such body is on disk"

    # ── how many of the vault's entries could authenticate ───────────────────
    WDC11=$(dcworld)
    printf '{"email":"c@example.com","login":"c@example.com","oauthAccount":{"emailAddress":"c@example.com"},"claudeAiOauth":{"accessToken":"","expiresAt":9999999999000}}\n' \
        > "$WDC11/vault/c@example.com.json"
    out=$(ddoc "$WDC11")
    report yes "$(dcsays "$out" switcher '3 logins, 2 with a token')" \
        "doctor: an entry whose access token is empty is in the vault and is not a login anything could authenticate as"

    # The figure is about what the vault CARRIES. A token that has since lapsed
    # is still a token; the probe is what calls it lapsed, and the decision then
    # runs on that login's frozen figures rather than skipping it.
    WDC11b=$(dcworld)
    printf '{"email":"c@example.com","login":"c@example.com","oauthAccount":{"emailAddress":"c@example.com"},"claudeAiOauth":{"accessToken":"t","expiresAt":1000000000000}}\n' \
        > "$WDC11b/vault/c@example.com.json"
    out=$(ddoc "$WDC11b"); rc=$?
    report 0 "$rc" "doctor: a vault entry whose token has lapsed is not a failure"
    report yes "$(dcsays "$out" switcher '3 logins, 3 with a token')" \
        "doctor: ... and it still counts, because the figure names what the entry carries, not what the endpoint would say"

    # ── the gap, with nothing on the switcher's side of it ───────────────────
    WDC12=$(dcworld); rm -f "$WDC12/data/switch-log.tsv"
    out=$(ddoc "$WDC12")
    report yes "$(dcsays "$out" switcher 'no decision recorded yet')" \
        "doctor: a switcher that has decided nothing says so"
    report yes "$(dcsays "$out" switcher 'newest cap death (5m)')" \
        "doctor: ... beside the cap death it did not act on, which is the gap worth seeing"

    # ── a vault entry filed under a name its own identity does not derive ────
    # The swap writes two files and the statusline's autosave reads both; land
    # between them and a credential is vaulted under another login's name. The
    # window is not guarded, and this is the detector that would turn that
    # judgement into a case to design against.
    WDC13=$(dcworld)
    printf '{"email":"d@example.com","login":"c@example.com","oauthAccount":{"emailAddress":"d@example.com"},"claudeAiOauth":{"accessToken":"t","expiresAt":9999999999000}}\n' \
        > "$WDC13/vault/c@example.com.json"
    out=$(ddoc "$WDC13"); rc=$?
    report 1 "$rc" "doctor: a vault entry whose own identity is not the name it is filed under is a failure"
    report FAIL "$(dcstate "$out" vault)" "doctor: ... on a line of its own"
    report yes "$(dcsays "$out" vault 'c@example.com.json')" "doctor: ... naming the file"
    report yes "$(dcsays "$out" vault 'd@example.com')" "doctor: ... and the identity the entry itself carries"
    report "" "$(dcstate "$DCOK" vault)" "doctor: a vault whose entries all derive their own names says nothing"

    # An entry nothing can read an identity out of is a different fault with a
    # different remedy, and the name-collision wording would send its reader to
    # .history for a restore that is not the answer.
    WDC13b=$(dcworld)
    printf '{"email":"e@example.com","login":"e@exa\n' > "$WDC13b/vault/e@example.com.json"
    out=$(ddoc "$WDC13b"); rc=$?
    report 1 "$rc" "doctor: a vault entry carrying no identity of its own is a failure too"
    report FAIL "$(dcstate "$out" vault)" "doctor: ... on the same line"
    report yes "$(dcsays "$out" vault 'no identity of its own')" "doctor: ... named as what it is"
    report no "$(dcsays "$out" vault 'another login')" \
        "doctor: ... and never as a credential filed under another login's name, which it is not"

    # ── the warn threshold, which `doctor` dispatches before the CLI validates
    out=$(ddoc "$WDC" USAGE_WARN_PCT=ninety); rc=$?
    report 1 "$rc" "doctor: a warn threshold that is not a whole number is a failure"
    report FAIL "$(dcstate "$out" 'warn pct')" \
        "doctor: ... named on its own line — until it is fixed every prompt is blocked with exit 2"
    report yes "$(dcsays "$out" 'warn pct' ninety)" "doctor: ... quoting the value it read"
    out=$(ddoc "$WDC" USAGE_WARN_PCT=95)
    report "" "$(dcstate "$out" 'warn pct')" "doctor: a threshold that is a whole number says nothing"

    WDC14=$(dcworld)
    printf 'USAGE_WARN_PCT="${USAGE_WARN_PCT:-ninety}"\n' > "$WDC14/cfg/session.conf"
    chmod 600 "$WDC14/cfg/session.conf"
    out=$(ddoc "$WDC14"); rc=$?
    report 1 "$rc" "doctor: the same value out of session.conf is caught, which is the case that used to report everything fine"
    report FAIL "$(dcstate "$out" 'warn pct')" "doctor: ... as a failure"
    report yes "$(dcsays "$out" 'warn pct' 'session.conf')" "doctor: ... naming the file that sets it"
fi

echo "--- swap-save: the blank-credential refusal inside a locked decision ---"

# The 2026-09-15 shape met by the DECISION rather than by the statusline: the
# live credential is structurally perfect and empty, so the swap's "never lose
# the login being replaced" save refuses — and it refuses inside the lock,
# because lock_run execs its command. Anything that refusal backgrounds there
# inherits the lock descriptor and holds switch.lock for as long as it lives,
# so a notifier that hangs (a push to a phone on a dead network) would leave
# every later decision reading the lock as another decision in flight.
if ! have jq || ! have perl; then
    skip "swap-save: the refusal inside the lock" "needs jq and perl"
else
    svent() {  # WORLD LOGIN TOKEN — a vault entry the candidate screening accepts
        printf '{"email":"%s","login":"%s","oauthAccount":{"emailAddress":"%s"},"claudeAiOauth":{"accessToken":"%s","expiresAt":9999999999000}}\n' \
            "$2" "$2" "$2" "$3" > "$1/vault/$2.json"
    }
    sbody() {  # STUB TOKEN FIVE WEEK FABLE
        local iso='2099-01-01T00:00:00+00:00'
        printf '{"limits":[{"kind":"session","percent":%s,"resets_at":"%s"},{"kind":"weekly_all","percent":%s,"resets_at":"%s"},{"kind":"weekly_scoped","percent":%s,"resets_at":"%s","scope":{"model":{"display_name":"Fable"}}}]}\n' \
            "$3" "$iso" "$4" "$iso" "$5" "$iso" > "$1/body.$2"
    }
    sworld() {  # -> a world whose live credential is blank and whose frozen 5h window is spent
        local w n; w=$(world); mkdir -p "$w/vault"; n=$(date +%s)
        mklogin "$w" a@example.com
        printf '{"claudeAiOauth":{"accessToken":"","refreshToken":"","expiresAt":0},"mcpOAuth":{"granola":"keep-me"}}\n' \
            > "$w/cfg/.credentials.json"
        svent "$w" a@example.com tok-a; svent "$w" b@example.com tok-b
        # An empty token is never sent, so the live login probes lapsed and is
        # ranked on the statusline cache instead — which is what puts a spent
        # five-hour window under it and makes the candidate admissible.
        mkcache "$w" a@example.com 95 10 $(( n + 600 )) $(( n + 6000 ))
        printf '%s\n' "$w"
    }
    sauto() {  # WORLD PATH NOTIFY — one decision, stderr folded in
        sess "$1" PATH="$2" SESSION_ACCOUNTS_DIR="$1/vault" \
            SESSION_SWITCH_NOTIFY="$3" -- account auto --trigger cap --sid sid-s 2>&1
    }
    skv() {  # KEY OUTPUT -> the value of one k=v line
        printf '%s\n' "$2" | awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }'
    }
    swait() {  # FILE LINES — the seam fires in the background, so poll for it
        local n=0
        while [ "$(grep -c . "$1" 2>/dev/null || echo 0)" -lt "$2" ] && [ "$n" -lt 25 ]; do
            sleep 0.2 2>/dev/null || sleep 1
            n=$(( n + 1 ))
        done
    }

    # ── a notifier that never returns must not pin the decision lock ─────────
    WS1=$(sworld); CS1=$(curlstub)
    sbody "$CS1" tok-b 10 10 10
    SHANG="$TMP/swap-save-hang.sh"; printf '#!/bin/sh\nsleep 30\n' > "$SHANG"; chmod 755 "$SHANG"
    out=$(sauto "$WS1" "$CS1:$PATH" "$SHANG"); rc=$?
    report 0 "$rc" "swap-save: a decision whose outgoing credential cannot be vaulted still switches"
    report switch "$(skv ev "$out")" "swap-save: ... saying so on its own output channel"
    report tok-b "$(jq -r '.claudeAiOauth.accessToken' "$WS1/cfg/.credentials.json")" \
        "swap-save: ... having installed the candidate's credential"
    report 0 "$(lock_run "$WS1/data/switch.lock" true >/dev/null 2>&1; echo $?)" \
        "swap-save: ... and holding the lock no longer, which a refusal fired inside it would"

    # ── the row is the durable record; the push is what the lock forbids ─────
    WS2=$(sworld); CS2=$(curlstub); SLOG2="$WS2/data/switch-log.tsv"
    sbody "$CS2" tok-b 10 10 10
    SNOTE="$TMP/swap-save-notified"; SNOTIFY="$TMP/swap-save-notify.sh"
    printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s"\n' "$SNOTE" > "$SNOTIFY"; chmod 755 "$SNOTIFY"
    sauto "$WS2" "$CS2:$PATH" "$SNOTIFY" >/dev/null
    report 1 "$(awk -F'\t' '$2 == "refuse"' "$SLOG2" | grep -c . || true)" \
        "swap-save: the refusal still writes its audit row, which is the record doctor reads"
    report 'refuse a@example.com - manual blank-credential -' \
        "$(awk -F'\t' '$2 == "refuse" { print $2, $3, $4, $5, $6, $7 }' "$SLOG2")" \
        "swap-save: ... naming the login it refused and why"
    report notify=off "$(awk -F'\t' '$2 == "refuse" { print $8 }' "$SLOG2")" \
        "swap-save: ... and recording that nothing was pushed, rather than claiming a push"
    # Two lines are waited for and one must arrive: the switch's, fired by the
    # parent once the locked child is gone. The wait has to outlast a second
    # that never comes, or a passing run would only be a fast one.
    swait "$SNOTE" 2
    report 1 "$(grep -c . "$SNOTE" 2>/dev/null || true)" \
        "swap-save: the switch is still announced, from outside the lock"
    report no "$(grep -q 'not vaulting' "$SNOTE" && echo yes || echo no)" \
        "swap-save: ... and the refusal beneath it announces nothing at all"

    # ── the swap's other caller, where no lock is involved at all ────────────
    # `use` is quiet for a different reason: the swap discards acct_save's
    # stderr, so this path has never shown the refusal either way, and the row
    # is the whole record of it.
    WS4=$(sworld); CS4=$(curlstub)
    sbody "$CS4" tok-a 10 10 10; sbody "$CS4" tok-b 10 10 10
    : > "$SNOTE"
    sess "$WS4" PATH="$CS4:$PATH" SESSION_ACCOUNTS_DIR="$WS4/vault" \
        SESSION_SWITCH_NOTIFY="$SNOTIFY" -- account use b@example.com >/dev/null 2>&1
    report notify=off "$(awk -F'\t' '$2 == "refuse" { print $8 }' "$WS4/data/switch-log.tsv")" \
        "swap-save [use]: a blank outgoing credential is recorded by the manual switch too"
    swait "$SNOTE" 1
    report 0 "$(grep -c . "$SNOTE" 2>/dev/null || true)" \
        "swap-save [use]: ... and announces nothing, there being no switch seam on this verb"

    # ── the same on the backend macOS runs ───────────────────────────────────
    # Without flock(1), lock_run locks through perl, which pins the descriptor
    # across the exec ($^F=10) — so a grandchild inherits the lock there too,
    # and the case has to be answered on both backends, not on this host's.
    SNOFLOCK=$(minipath flock)
    if PATH="$SNOFLOCK" command -v flock >/dev/null 2>&1; then
        skip "swap-save [perl]" "flock is still on the minimal PATH"
    else
        WS3=$(sworld); CS3=$(curlstub)
        sbody "$CS3" tok-b 10 10 10
        out=$(sauto "$WS3" "$CS3:$SNOFLOCK" "$SHANG")
        report switch "$(skv ev "$out")" "swap-save [perl]: the decision switches under the perl lock too"
        report 0 "$(lock_run "$WS3/data/switch.lock" true >/dev/null 2>&1; echo $?)" \
            "swap-save [perl]: ... and leaves the lock free behind it"
    fi
fi

echo "--- lock-open: an unopenable lock file is not a busy lock ---"

# A backend has to separate "somebody holds this lock" from "this lock file
# cannot be opened at all". Every caller reads the busy codes — 1 from flock(1),
# 75 from the perl fallback — as "another decision is in flight" and falls
# through with no retry, no audit row and no message, so an unopenable
# switch.lock reported as busy would disable automatic switching for ever and
# say nothing about it. flock(1) reports EX_NOINPUT (66) for that condition and
# the perl fallback — the backend macOS takes, having no flock(1) — has to agree.
LKO="$TMP/lockopen-unopenable"
: > "$LKO"
chmod 444 "$LKO"
if ! have perl; then
    skip "lock-open [perl]" "no perl"
elif ( : >> "$LKO" ) 2>/dev/null; then
    skip "lock-open [perl]" "a mode-444 file is still openable here (running as root)"
else
    LKOBIN=$(minipath flock)
    if PATH="$LKOBIN" command -v flock >/dev/null 2>&1; then
        skip "lock-open [perl]" "flock is still on the minimal PATH"
    else
        lko_rc=$( PATH="$LKOBIN"; lock_run "$LKO" ls >/dev/null 2>&1; echo $? )
        report 66 "$lko_rc" "lock-open [perl]: a lock file that cannot be opened reports 66"
        report no "$( { [ "$lko_rc" = 1 ] || [ "$lko_rc" = 75 ]; } && echo yes || echo no)" \
            "lock-open [perl]: ... which is outside the busy set a caller falls through on"

        # The other half of the same contract: a lock somebody holds still reports
        # busy, so the two conditions are separated rather than one renamed.
        LKOH="$TMP/lockopen-held"
        rm -f "$LKOH" "$TMP/lockopen.ran"
        ( PATH="$LKOBIN"; lock_run "$LKOH" sh -c "touch '$TMP/lockopen.ran'; sleep 3" ) &
        lkopid=$!
        lkon=0
        while [ ! -e "$TMP/lockopen.ran" ] && [ "$lkon" -lt 10 ]; do sleep 1; lkon=$(( lkon + 1 )); done
        lkoh_rc=$( PATH="$LKOBIN"; lock_run "$LKOH" ls >/dev/null 2>&1; echo $? )
        wait "$lkopid"
        rm -f "$TMP/lockopen.ran"
        report 75 "$lkoh_rc" "lock-open [perl]: a lock another process holds still reports busy"

        # The prune is the lock's other caller, and the live logs are what it has
        # at stake: it may replace one only when the awk under the lock ran to
        # completion, which a lock it could never open is not.
        LKOR="$TMP/lockopen-prune"
        rm -rf "$LKOR"; mkdir -p "$LKOR"
        lko_old=$(( PRUNE_NOW - 10 * 86400 )); lko_new=$(( PRUNE_NOW - 86400 ))
        for lg in turn-log session-log focus-log; do
            printf '%s\tsid\told\n%s\tsid\tnew\n' "$lko_old" "$lko_new" > "$LKOR/$lg.tsv"
            : > "$LKOR/$lg.tsv.lock"
            chmod 444 "$LKOR/$lg.tsv.lock"
        done
        probe 'session_prune_daily' SESSION_DATA_DIR="$LKOR" SESSION_NOW="$PRUNE_NOW" \
            PATH="$LKOBIN" >/dev/null 2>&1
        report 2 "$(wc -l < "$LKOR/turn-log.tsv" | tr -d ' ')" \
            "lock-open [perl]: a prune whose lock file cannot be opened leaves the live turn log intact"
        report 2 "$(wc -l < "$LKOR/session-log.tsv" | tr -d ' ')" \
            "lock-open [perl]: ... and the session log"
        report absent "$([ -s "$LKOR/archive/turn-log.tsv" ] && echo present || echo absent)" \
            "lock-open [perl]: ... and archives nothing"
        rm -rf "$LKOR"
    fi
fi
rm -f "$LKO"

echo "--- mis-filed: a vault entry holding the live credential is not a switch target ---"

# The statusline's unlocked autosave can land inside the swap's two-file window
# and file the incoming credential under the outgoing login's name. The
# screening excludes the live login BY NAME and acct_swap's post-condition
# compares what it installed against the ENTRY's credential, so such an entry
# passes both: nothing is installed, the readback confirms success, and the box
# announces a switch and wakes a capped session onto a login it never left. The
# session then retries into the same cap.
if ! have jq || ! have perl; then
    skip "mis-filed: an entry holding the live credential" "needs jq and perl"
else
    MNOW=$(date +%s); MFUT=$(( MNOW + 36000 )); MEXP=$(( MNOW + 3600 ))
    mvent() {  # WORLD LOGIN TOKEN — a vault entry under LOGIN's name carrying TOKEN
        printf '{"email":"%s","login":"%s","oauthAccount":{"emailAddress":"%s"},"claudeAiOauth":{"accessToken":"%s","expiresAt":%s000}}\n' \
            "$2" "$2" "$2" "$3" "$MEXP" > "$1/vault/$2.json"
    }
    # The box live on b@ and capped, with a@ vaulted and clean. Both logins are
    # read from their frozen caches: the endpoint answers nothing here, the state
    # `doctor` reports as a supported pending rather than a fault, and the one in
    # which a mis-filed entry ranks on the figures of the login it is named for.
    mworld() {
        local w; w=$(world); mkdir -p "$w/vault"
        mklogin "$w" b@example.com
        # The live file carries a refresh token the vault entries do not, so the
        # screening cannot rest on the two claudeAiOauth objects being equal
        # byte for byte: what decides whether a switch moves the box to another
        # account is the ACCESS token, and an entry holding the live one moves
        # nothing whatever else it carries.
        printf '{"claudeAiOauth":{"accessToken":"tok-b","refreshToken":"rt-b","expiresAt":%s000},"mcpOAuth":{"granola":"keep-me"}}\n' \
            "$MEXP" > "$w/cfg/.credentials.json"
        mvent "$w" b@example.com tok-b
        mkcache "$w" b@example.com 99 99 "$MFUT" "$MFUT"
        mkcache "$w" a@example.com 3 3 "$MFUT" "$MFUT"
        printf '{"fable":{"used_percentage":3,"resets_at":%s}}\n' "$MFUT" > "$w/data/fable.a@example.com.json"
        printf '%s\n' "$w"
    }
    mauto() {  # WORLD STUB SID — one decision, stderr folded in
        sess "$1" PATH="$2:$PATH" SESSION_ACCOUNTS_DIR="$1/vault" SESSION_NOW="$MNOW" \
            SESSION_SWITCH_NOTIFY="$MNOTIFY" -- account auto --trigger cap --sid "$3" 2>&1
    }
    mkv() { printf '%s\n' "$2" | awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }'; }
    # The seam fires in the background, so poll for it. Counted with awk rather
    # than `grep -c .`, which exits 1 on an empty file: a `|| echo 0` beside it
    # then prints two zeroes, the comparison is not an integer, and the loop
    # falls through having waited for nothing — which is how an assertion that
    # nothing was announced passes without ever giving it time to arrive.
    mwait() {  # FILE LINES
        local n=0
        while [ "$(awk 'END { print NR + 0 }' "$1" 2>/dev/null || echo 0)" -lt "$2" ] && [ "$n" -lt 25 ]; do
            sleep 0.2 2>/dev/null || sleep 1
            n=$(( n + 1 ))
        done
    }

    MNOTE="$TMP/misfiled-notified"
    MNOTIFY="$TMP/misfiled-notify.sh"
    printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s"\n' "$MNOTE" > "$MNOTIFY"; chmod 755 "$MNOTIFY"

    MW1=$(mworld); MC1=$(curlstub); MLOG1="$MW1/data/switch-log.tsv"
    mvent "$MW1" a@example.com tok-b        # a@'s name over the credential already live
    printf '000' > "$MC1/status.tok-b"
    : > "$MNOTE"
    out=$(mauto "$MW1" "$MC1" sid-m1); rc=$?
    report 3 "$rc" "mis-filed: an entry carrying the live credential is held on, never switched to"
    report 'hold no-candidate' "$(mkv ev "$out") $(mkv reason "$out")" \
        "mis-filed: ... there being nothing left to rank once it is screened out"
    report tok-b "$(jq -r '.claudeAiOauth.accessToken' "$MW1/cfg/.credentials.json")" \
        "mis-filed: ... with the live credential where it was"
    report b@example.com "$(jq -r '.oauthAccount.emailAddress' "$MW1/cfg/.claude.json")" \
        "mis-filed: ... and the identity still naming the login actually serving requests"
    report 0 "$(awk -F'\t' '$2 == "switch"' "$MLOG1" | grep -c . || true)" \
        "mis-filed: ... no switch row, which is what a waiter with no output of its own reads back"
    mwait "$MNOTE" 1
    report 0 "$(grep -c . "$MNOTE" 2>/dev/null || true)" \
        "mis-filed: ... and nothing announced, the announcement being what wakes a capped session"

    # The same world with a@'s own credential in its entry: the screen rejects a
    # duplicate of the live credential and nothing else.
    MW2=$(mworld); MC2=$(curlstub)
    mvent "$MW2" a@example.com tok-a
    printf '000' > "$MC2/status.tok-b"; printf '000' > "$MC2/status.tok-a"
    : > "$MNOTE"
    out=$(mauto "$MW2" "$MC2" sid-m2); rc=$?
    report 0 "$rc" "mis-filed: an entry carrying its own login's credential is still a candidate"
    report 'switch a@example.com' "$(mkv ev "$out") $(mkv to "$out")" \
        "mis-filed: ... and the box moves to it"
    report tok-a "$(jq -r '.claudeAiOauth.accessToken' "$MW2/cfg/.credentials.json")" \
        "mis-filed: ... having installed the credential that was not there before"
    mwait "$MNOTE" 1
    report 1 "$(grep -c . "$MNOTE" 2>/dev/null || true)" \
        "mis-filed: ... and says so, which is the wake a real switch owes a capped session"
fi

echo "--- cooldown-refuse: a blank-credential refusal is not a decision to wait behind ---"

# The cooldown is measured against the newest row THIS VERB wrote. A refusal is
# another producer's: the statusline writes one per login per cooldown while the
# live access token is blank, and the outage that produces a run of them is
# exactly when an authentication death most needs a decision. Counting one would
# park the box on a login that cannot authenticate for as long as the refusals
# kept coming. The fixture is the decision verb's, built with the `decide` cases
# above and guarded the same way.
if ! have jq || ! have perl; then
    skip "cooldown-refuse: a refusal does not hold a decision" "needs jq and perl"
else
    DCLOCK=$DNOW; DNOTIFY=""
    WCR=$(dworld); CCR=$(curlstub); DLOGCR="$WCR/data/switch-log.tsv"
    dlive "$WCR" a@example.com tok-a
    dvent "$WCR" a@example.com tok-a; dvent "$WCR" b@example.com tok-b
    dbody "$CCR" tok-a 95 10 10; dbody "$CCR" tok-b 10 10 10
    printf '%s\trefuse\ta@example.com\t-\tmanual\tblank-credential\t-\tnotify=off\n' \
        $(( DNOW - 100 )) > "$DLOGCR"
    out=$(dauto "$WCR" "$CCR" --trigger auth --sid sid-cr); rc=$?
    report 0 "$rc" "cooldown-refuse: an authentication death 100s after a refusal still decides"
    report 'switch b@example.com' "$(dkv ev "$out") $(dkv to "$out")" \
        "cooldown-refuse: ... the refusal being another producer's row, not a decision to wait behind"
    report tok-b "$(jq -r '.claudeAiOauth.accessToken' "$WCR/cfg/.credentials.json")" \
        "cooldown-refuse: ... so the box reaches the login that can serve it"
fi

echo "--- next-eligible: a candidate's Fable reset promotes it only above a Fable-only live login ---"

# Rows are `login TAB blocks TAB 5h_reset TAB week_reset TAB fable_reset TAB
# state`, as the decision builds them. A tier-0 live login — a general window
# spent — is beaten by any tier-1 candidate, so a candidate blocked on its
# five-hour window and on Fable climbs the moment the five-hour one clears:
# naming its Fable reset as well would send a waiter to sleep past the time
# something changed. Only a live login blocked on nothing but Fable makes the
# candidate clear all three.
report 1000 "$(printf 'x\t5h,fable\t1000\t0\t5000\tgood\n' | _acct_next_eligible 0)" \
    "next-eligible: a tier-0 live login is climbed as soon as the candidate's five-hour window clears"
report 5000 "$(printf 'x\t5h,fable\t1000\t0\t5000\tgood\n' | _acct_next_eligible 1)" \
    "next-eligible: ... while over a Fable-only live login the candidate's Fable window has to clear too"
report - "$(printf 'x\t5h,fable\t1000\t0\t5000\tgood\n' | _acct_next_eligible 2)" \
    "next-eligible: ... and nothing stands above tier 2, so no reset promotes anything"

echo
echo "$pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
