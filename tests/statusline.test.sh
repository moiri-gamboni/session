#!/usr/bin/env bash
# Suite for the statusline: bash tests/statusline.test.sh
#
# Cases 20-25: the statusline render. Everything here is an effect of one
# real render: a payload goes in on stdin and the case reads what landed under
# the data root. Nothing is asserted through the CLI — the cache and snapshot
# readbacks use the same jq programs `session` uses, quoted here, so this suite
# stays green while `session` itself is being re-rooted in parallel.
#
# The fixture is a COPY of statusline.sh and lib/ under $TMP, because
# SESSION_HOME is resolved from the script's own path: copying makes the fixture
# dir the SESSION_HOME, which is how case 24 gets a recording `session` stub in
# the place the credential autosave calls.
#
# The suite's own umask is forced to 022 so the 700/600 assertions can only be
# satisfied by the umask the lib sets inside the render. Do not source the lib
# here — that would set 077 for the fixtures too, and the mode cases would pass
# for a reason that is not the one under test.
#
# jq is required by every case (the statusline is a jq program with a shell
# around it); without it the whole suite skips.
set -uo pipefail
umask 022

SUITE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SDIR=$(dirname "$SUITE")
SL="$SDIR/statusline.sh"
LIB="$SDIR/lib/common.sh"
[ -r "$SL" ]  || { echo "statusline.sh not found beside this suite" >&2; exit 2; }
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
yesno() { if "$@"; then echo yes; else echo no; fi; }
exists() { if [ -e "$1" ]; then echo present; else echo absent; fi; }
endswith() { case "$1" in *"$2") return 0 ;; *) return 1 ;; esac; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
TAB=$'\t'

# The two displayed rate-limit percentages, pulled out of the rendered line.
# Only the percentages: the countdowns beside them are wall-clock differences
# between fixture time and render time, so asserting those would pin the clock
# rather than the selection. Empty output means the line had no 5h/wk pair at
# all, which is a legible failure rather than a silent match.
pcts() { printf '%s\n' "$1" | sed -n 's/.*5h: \([^ ,]*\).*wk: \([^ ,]*\).*/\1 \2/p'; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FH="$TMP/home"; mkdir -p "$FH"

if ! have jq; then
    skip "cases 20-25: the statusline suite" "no jq — the statusline cannot render without it"
    echo
    echo "$pass passed, $fail failed, $skipped skipped"
    exit 0
fi

# ── fixtures ─────────────────────────────────────────────────────────────────

# SESSION_HOME under test: the shipped statusline and lib, plus a stub `session`
# that records how the credential autosave called it.
SHOME="$TMP/shome"
mkdir -p "$SHOME/lib"
cp "$SL" "$SHOME/statusline.sh"
cp "$SDIR"/lib/*.sh "$SHOME/lib/"
CALLS="$SHOME/.session-calls"
cat > "$SHOME/session" <<'STUBEOF'
#!/usr/bin/env bash
# Recording stub. The autosave is supposed to reach the `session` beside the
# statusline, so the record lives beside this script too — no environment
# plumbing, which matters because the render runs under `env -i`.
printf '%s\n' "$*" >> "$(dirname "$0")/.session-calls"
STUBEOF
chmod +x "$SHOME/session"
report yes "$(yesno test -x "$SHOME/session")" "fixture: the session stub is executable"
report yes "$(yesno test -s "$SHOME/lib/common.sh")" "fixture: the lib was copied beside the statusline"

CFG="$TMP/cfg"; mkdir -p "$CFG"
ACCT="tester@example.com"
printf '{"oauthAccount":{"emailAddress":"%s"}}\n' "$ACCT" > "$CFG/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"live-token"}}\n' > "$CFG/.credentials.json"
VAULT="$TMP/vault"; mkdir -p "$VAULT"

SID="11111111-1111-1111-1111-111111111111"
NOW=$(date +%s)
FR=$(( NOW + 3600 ))    # a five-hour window that has not reset yet
WR=$(( NOW + 86400 ))   # ditto the weekly

# A realistic payload: the key set and nesting of a live Claude Code statusline
# payload (structure taken from a real cache file, values invented). cwd,
# transcript_path and workspace are in it precisely because the point of case 20
# is that they do NOT reach the disk.
mkpayload() {  # sid cost five_pct week_pct five_reset week_reset session_name
    cat <<EOF
{
  "session_id": "$1",
  "transcript_path": "$FH/.claude/projects/-fixture/$1.jsonl",
  "cwd": "$FH/work",
  "prompt_id": "prompt-abc",
  "effort": {"level": "high"},
  "session_name": "$7",
  "model": {"id": "claude-fable-5", "display_name": "Fable 5"},
  "workspace": {"current_dir": "$FH/work", "project_dir": "$FH/work",
                "git_worktree": "$FH/work",
                "repo": {"host": "github.com", "owner": "example", "name": "tool"}},
  "version": "2.1.251",
  "output_style": {"name": "default"},
  "cost": {"total_cost_usd": $2, "total_duration_ms": 123456, "total_api_duration_ms": 65432,
           "total_lines_added": 12, "total_lines_removed": 3},
  "context_window": {"total_input_tokens": 57775, "total_output_tokens": 10,
                     "context_window_size": 1000000,
                     "current_usage": {"input_tokens": 2, "output_tokens": 10,
                                       "cache_creation_input_tokens": 36063,
                                       "cache_read_input_tokens": 21710},
                     "used_percentage": 6, "remaining_percentage": 94},
  "exceeds_200k_tokens": false,
  "thinking": {"enabled": true},
  "rate_limits": {"five_hour": {"used_percentage": $3, "resets_at": $5},
                  "seven_day": {"used_percentage": $4, "resets_at": $6}}
}
EOF
}

render() {  # render PAYLOAD_FILE [VAR=VAL ...] -> the status line on stdout
    local pf="$1"; shift
    env -i PATH="$PATH" HOME="$FH" TZ=UTC \
        CLAUDE_CONFIG_DIR="$CFG" SESSION_ACCOUNTS_DIR="$VAULT" \
        ${1+"$@"} bash "$SHOME/statusline.sh" < "$pf"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

echo "--- case 20: the cache carries only what is read back ---"

D20="$TMP/data20"           # deliberately absent: the render has to create it
P20a="$TMP/p20a.json"; mkpayload "$SID" 0.1234 41 62 "$FR" "$WR" "case twenty" > "$P20a"
P20b="$TMP/p20b.json"; mkpayload "$SID" 0.4321 47 63 "$FR" "$WR" "case twenty" > "$P20b"
CACHE20="$D20/last-status.$ACCT.json"

# First sighting of this (session, pane): the tuple's owner is unknowable, so the
# render records it unowned and writes no cache. That is the pre-condition of the
# attribution rule, not an aside — without it the second render proves nothing.
line20a=$(render "$P20a" SESSION_DATA_DIR="$D20")
report absent "$(exists "$CACHE20")" "case 20: a first-sighting render writes no cache (the tuple is unowned)"
report yes "$(yesno test -n "$line20a")" "case 20: it still renders a status line"
report 1 "$(printf '%s\n' "$line20a" | wc -l | tr -d ' ')" "case 20: the render is exactly one line"

# Second render, moved windows: a changed tuple proves a response arrived under
# the live login, so this one writes the cache.
line20b=$(render "$P20b" SESSION_DATA_DIR="$D20")
report present "$(exists "$CACHE20")" "case 20: a changed rate-limit tuple writes the cache"
report "context_window,model,rate_limits,version" "$(jq -r 'keys|join(",")' "$CACHE20")" \
    "case 20: the cache carries exactly the four allowlisted keys"
report "absent,absent,absent,absent,absent" \
    "$(jq -r '[.cwd, .transcript_path, .workspace, .session_id, .cost] | map(if . == null then "absent" else "PRESENT" end) | join(",")' "$CACHE20")" \
    "case 20: cwd, transcript_path, workspace, session_id and cost do not reach the disk"

# Readback with the jq programs the CLI's overview and --json use, so what is
# asserted is that the cache is still a usable input, not merely that it is small.
report "47${TAB}${FR}${TAB}63${TAB}${WR}${TAB}6${TAB}Fable 5" \
    "$(jq -r '[ (.rate_limits.five_hour.used_percentage // -1),
                (.rate_limits.five_hour.resets_at // 0),
                (.rate_limits.seven_day.used_percentage // -1),
                (.rate_limits.seven_day.resets_at // 0),
                (.context_window.used_percentage // -1),
                (.model.display_name // .model.id // "?") ] | @tsv' "$CACHE20")" \
    "case 20: the overview's six fields read back off the cache"
report '{"rate_limits":{"five_hour":{"used_percentage":47,"resets_at":'"$FR"'},"seven_day":{"used_percentage":63,"resets_at":'"$WR"'}},"context_pct":6,"model":"Fable 5"}' \
    "$(jq -c '{rate_limits, context_pct: .context_window.used_percentage, model: .model.display_name}' "$CACHE20")" \
    "case 20: the --json projection reads back off the cache"
report "2.1.251" "$(jq -r '.version' "$CACHE20")" "case 20: the version survives (session doctor prints it)"

report 700 "$(mode_of "$D20")"           "case 20: the data root the render created is 700"
report 600 "$(mode_of "$CACHE20")"       "case 20: the cache file is 600"
report 700 "$(mode_of "$D20/sessions")"  "case 20: the snapshot directory is 700"
report "*" "$(cat "$D20/.gitignore" 2>/dev/null)" "case 20: the data root carries a .gitignore of '*'"
report absent "$(if ls "$D20"/last-status.*.tmp* >/dev/null 2>&1; then echo present; else echo absent; fi)" \
    "case 20: no temporary file is left beside the cache"
report yes "$(yesno test -n "$line20b")" "case 20: the writing render also prints its line"

# A render that cannot read its payload must leave the store as it found it.
# Both writes go through a temp file in the same directory and an `&& mv`, so
# there is no state in which a reader sees half a cache or a half snapshot.
cache_before=$(cat "$CACHE20")
printf 'not json at all\n' > "$TMP/garbage"
render "$TMP/garbage" SESSION_DATA_DIR="$D20" >/dev/null 2>&1
report "$cache_before" "$(cat "$CACHE20")" "case 20: a malformed payload leaves the cache exactly as it was"
report absent "$(if ls "$D20"/last-status.*.tmp* >/dev/null 2>&1; then echo present; else echo absent; fi)" \
    "case 20: ... and leaves no half-written temp file"

echo "--- overlapping renders of one login: the cache survives them whole ---"

# Every render of one login writes the same cache, and renders overlap: several
# sessions on one login answer within the same second, and each re-renders every
# ~10s. A temp name SHARED between two writers is a truncate-and-overwrite race:
# the second `>` truncates the first writer's temp, the shorter write then lands
# over the longer one, and the longer one's tail survives past the shorter's end.
# Observed 2026-09-14: a complete JSON line followed by a stray `"}`, and
# `session account` printing a jq parse error over it for a day — a non-live
# login's cache is only rewritten by a render on that login.
#
# The overlap is forced, not raced for: a jq shim on PATH delays one write (the
# filter named in .target) by payload — the longer payload lands first, the
# shorter one lands over it — so a shared temp name corrupts every time, and a
# per-writer name leaves both writes whole. One run per write, since delaying
# the cache write has put the two renders out of step by the time they reach
# the snapshot. The control pins that the shim intercepted both writes of a run;
# without it a filter change would turn the case into a coin toss.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
cat > "$SHIM/jq" <<SHIMEOF
#!/usr/bin/env bash
REAL="$(command -v jq)"
if [ "\${2:-}" = "\$(cat "$SHIM/.target")" ]; then
    input=\$(cat)
    printf '%s\n' "\$2" >> "$SHIM/.hits"
    case "\$input" in *'"session_name": "slow'*) sleep 0.6 ;; *) sleep 0.2 ;; esac
    printf '%s\n' "\$input" | exec "\$REAL" "\$@"
fi
exec "\$REAL" "\$@"
SHIMEOF
chmod +x "$SHIM/jq"
PRA="$TMP/pra.json"; mkpayload "$SID" 0.01 5 5 "$FR" "$WR" "primer" > "$PRA"
PRB="$TMP/prb.json"; mkpayload "$SID" 0.02 6 6 "$FR" "$WR" "primer" > "$PRB"
PFAST="$TMP/pfast.json"; mkpayload "$SID" 0.1 100 100 "$FR" "$WR" "fast, and the longer of the two" > "$PFAST"
PSLOW="$TMP/pslow.json"; mkpayload "$SID" 0.2 1 1 "$FR" "$WR" "slow" > "$PSLOW"
race_run() {  # FILTER DATA_ROOT — two overlapping renders of one login, the named write forced to overlap
    printf '%s\n' "$1" > "$SHIM/.target"
    # One sighting per pane first, so both overlapping renders carry a CHANGED
    # tuple and both write (a first sighting is unowned and writes nothing).
    render "$PRA" SESSION_DATA_DIR="$2" TMUX_PANE=%1 >/dev/null
    render "$PRB" SESSION_DATA_DIR="$2" TMUX_PANE=%2 >/dev/null
    : > "$SHIM/.hits"
    render "$PFAST" SESSION_DATA_DIR="$2" TMUX_PANE=%1 PATH="$SHIM:$PATH" >/dev/null &
    render "$PSLOW" SESSION_DATA_DIR="$2" TMUX_PANE=%2 PATH="$SHIM:$PATH" >/dev/null &
    wait
}
isjson() { jq -e . "$1" >/dev/null 2>&1; }
one_of() { [ "$1" = "$2" ] || [ "$1" = "$3" ]; }
report yes "$(yesno test "$(wc -c < "$PFAST")" -gt "$(wc -c < "$PSLOW")")" \
    "race: (control) the payload that lands first is the longer one"

DR1="$TMP/datarace1"
race_run '{rate_limits, context_window, model, version}' "$DR1"
report 2 "$(wc -l < "$SHIM/.hits" | tr -d ' ')" "race: (control) the shim intercepted both cache writes"
CACHER="$DR1/last-status.$ACCT.json"
report yes "$(yesno isjson "$CACHER")" "race: the cache is still one JSON value"
report yes "$(yesno one_of "$(cat "$CACHER")" \
              "$(jq -c '{rate_limits, context_window, model, version}' "$PFAST")" \
              "$(jq -c '{rate_limits, context_window, model, version}' "$PSLOW")")" \
    "race: ... and byte-identical to one of the two renders' caches, never a splice of both"
report absent "$(if ls "$DR1"/last-status.*.tmp* >/dev/null 2>&1; then echo present; else echo absent; fi)" \
    "race: neither render leaves a temp file beside the cache"

DR2="$TMP/datarace2"
race_run '{session_name}' "$DR2"
report 2 "$(wc -l < "$SHIM/.hits" | tr -d ' ')" "race: (control) the shim intercepted both snapshot writes"
SNAPR="$DR2/sessions/$SID.json"
report yes "$(yesno isjson "$SNAPR")" "race: the snapshot is still one JSON value"
report yes "$(yesno one_of "$(cat "$SNAPR")" '{"session_name":"fast, and the longer of the two"}' '{"session_name":"slow"}')" \
    "race: ... and is one of the two renders' snapshots whole"
report absent "$(if ls "$DR2/sessions"/.*.tmp* >/dev/null 2>&1; then echo present; else echo absent; fi)" \
    "race: neither render leaves a temp file in the snapshot directory"

echo "--- case 21: one session-log row per changed cost ---"

D21="$TMP/data21"
SLOG21="$D21/session-log.tsv"
P21a="$TMP/p21a.json"; mkpayload "$SID" 0.1234 41 62 "$FR" "$WR" "case twentyone" > "$P21a"
P21b="$TMP/p21b.json"; mkpayload "$SID" 0.5678 41 62 "$FR" "$WR" "case twentyone" > "$P21b"

render "$P21a" SESSION_DATA_DIR="$D21" >/dev/null
report 1 "$(wc -l < "$SLOG21" | tr -d ' ')" "case 21: the first render appends one row"
report 21 "$(awk -F'\t' '{print NF}' "$SLOG21" | sort -u | tr -d '\n ')" \
    "case 21: the row has 21 tab-separated columns"
report "${SID}${TAB}0.1234" "$(awk -F'\t' 'NR==1{printf "%s\t%s", $2, $3}' "$SLOG21")" \
    "case 21: columns 2 and 3 are the session id and the cost to four places"
report "$ACCT" "$(awk -F'\t' 'NR==1{print $21}' "$SLOG21")" \
    "case 21: column 21 is the login the sample belongs to"

render "$P21a" SESSION_DATA_DIR="$D21" >/dev/null
report 1 "$(wc -l < "$SLOG21" | tr -d ' ')" "case 21: an identical second render appends nothing"

render "$P21b" SESSION_DATA_DIR="$D21" >/dev/null
report 2 "$(wc -l < "$SLOG21" | tr -d ' ')" "case 21: a moved cost appends the next row"
report "0.5678" "$(awk -F'\t' 'NR==2{print $3}' "$SLOG21")" "case 21: ... carrying the new cost"

echo "--- case 22: the snapshot and the pane map ---"

D22="$TMP/data22"
P22="$TMP/p22.json"; mkpayload "$SID" 0.9876 41 62 "$FR" "$WR" "Port the statusline" > "$P22"
render "$P22" SESSION_DATA_DIR="$D22" TMUX_PANE=%42 >/dev/null

SNAP22="$D22/sessions/$SID.json"
report present "$(exists "$SNAP22")" "case 22: the per-session snapshot is written"
report "session_name" "$(jq -r 'keys|join(",")' "$SNAP22")" "case 22: the snapshot carries only session_name"
report "Port the statusline" "$(jq -r '.session_name // empty' "$SNAP22")" \
    "case 22: ... and the title reads back off it, which is all snap_name asks for"
report 600 "$(mode_of "$SNAP22")" "case 22: the snapshot is 600"
report absent "$(if ls "$D22/sessions"/.*.tmp* >/dev/null 2>&1; then echo present; else echo absent; fi)" \
    "case 22: no temporary file is left in the snapshot directory"
report "$SID" "$(cat "$D22/panes/42" 2>/dev/null)" \
    "case 22: the pane map records the session under the data root when TMUX_PANE is set"

D22b="$TMP/data22b"
render "$P22" SESSION_DATA_DIR="$D22b" >/dev/null
report absent "$(exists "$D22b/panes")" "case 22: no pane map outside tmux"

echo "--- case 23: two panes of one session keep separate limit sidecars ---"

D23="$TMP/data23"
P23a="$TMP/p23a.json"; mkpayload "$SID" 0.1 10 20 "$FR" "$WR" "two panes" > "$P23a"
P23b="$TMP/p23b.json"; mkpayload "$SID" 0.2 30 40 "$FR" "$WR" "two panes" > "$P23b"
P23c="$TMP/p23c.json"; mkpayload "$SID" 0.3 50 60 "$FR" "$WR" "two panes" > "$P23c"

render "$P23a" SESSION_DATA_DIR="$D23" TMUX_PANE=%1 >/dev/null
render "$P23b" SESSION_DATA_DIR="$D23" TMUX_PANE=%2 >/dev/null
report "present present" "$(exists "$D23/sessions/$SID.p1.limits") $(exists "$D23/sessions/$SID.p2.limits")" \
    "case 23: each pane of the same session id gets its own .limits sidecar"
report "10 20 $FR ${WR}${TAB}-" "$(cat "$D23/sessions/$SID.p1.limits")" \
    "case 23: pane 1 holds its own tuple, unowned on first sighting"
report "30 40 $FR ${WR}${TAB}-" "$(cat "$D23/sessions/$SID.p2.limits")" \
    "case 23: pane 2 holds a different tuple"

# The point of the split: one pane advancing must not stamp the other pane's
# stale payload with the live login (that is the 5h-19%-while-capped failure).
render "$P23c" SESSION_DATA_DIR="$D23" TMUX_PANE=%1 >/dev/null
report "50 60 $FR ${WR}${TAB}${ACCT}" "$(cat "$D23/sessions/$SID.p1.limits")" \
    "case 23: a moved tuple in pane 1 becomes owned by the live login"
report "30 40 $FR ${WR}${TAB}-" "$(cat "$D23/sessions/$SID.p2.limits")" \
    "case 23: ... and pane 2's sidecar is untouched"

# The sidecar split is the mechanism; what pane 2 then DISPLAYS is the outcome
# it exists for, and the sidecar assertions above never reach it.
#
# Pane 2 here is replaying a frozen payload whose tuple has never moved, so it
# is unowned — and an unowned payload is untrusted by construction. The rule is
# to show the account's own cache, the newest windows any pane has proved, not
# the numbers this pane happens to be holding. Printing its own 30% would be
# the 2026-08-26 shape exactly: a stale payload presented as current.
line23_p2=$(render "$P23b" SESSION_DATA_DIR="$D23" TMUX_PANE=%2)
report "50% 60%" "$(pcts "$line23_p2")" \
    "case 23: pane 2's unowned re-render displays the account's newest proven windows"
report no "$(yesno has "$line23_p2" '5h: 30%')" \
    "case 23: ... never the frozen 30% its own payload carries"
report 50 "$(jq -r '.rate_limits.five_hour.used_percentage' "$D23/last-status.$ACCT.json")" \
    "case 23: ... and that render does not write the cache back down to it"

# The other arm, and the one that needs the per-pane split to work at all: once
# pane 2 has had a proven-fresh render of its own, its sidecar is owned by the
# live login and its re-render shows ITS OWN window state — while pane 1 shows
# pane 1's. Two panes of one session id, two independent readings.
D23b="$TMP/data23b"
P23d="$TMP/p23d.json"; mkpayload "$SID" 0.4 35 41 "$FR" "$WR" "two panes" > "$P23d"
render "$P23a" SESSION_DATA_DIR="$D23b" TMUX_PANE=%1 >/dev/null   # pane 1, first sighting
render "$P23b" SESSION_DATA_DIR="$D23b" TMUX_PANE=%2 >/dev/null   # pane 2, first sighting
render "$P23d" SESSION_DATA_DIR="$D23b" TMUX_PANE=%2 >/dev/null   # pane 2 moves: owned, 35/41
render "$P23c" SESSION_DATA_DIR="$D23b" TMUX_PANE=%1 >/dev/null   # pane 1 moves: owned, cache 50/60
report "35% 41%" "$(pcts "$(render "$P23d" SESSION_DATA_DIR="$D23b" TMUX_PANE=%2)")" \
    "case 23: an owned pane 2 keeps displaying its own windows"
report "50% 60%" "$(pcts "$(render "$P23c" SESSION_DATA_DIR="$D23b" TMUX_PANE=%1)")" \
    "case 23: ... while pane 1 displays its own, in the same session id"

echo "--- the displayed rate-limit numbers (the fresh/owned/foreign/stale selection) ---"

# Cases 20-24 assert the files a render writes. These assert the line it PRINTS.
# That is the half both dated incidents in statusline.sh's comments were about —
# the number a person reads off the status bar when deciding whether there is
# budget left — and until now nothing in this suite looked at it.

DS="$TMP/dataseg"
PS1="$TMP/ps1.json"; mkpayload "$SID" 0.1 41 62 "$FR" "$WR" "seg" > "$PS1"
PS2="$TMP/ps2.json"; mkpayload "$SID" 0.2 47 63 "$FR" "$WR" "seg" > "$PS2"
render "$PS1" SESSION_DATA_DIR="$DS" >/dev/null
seg_fresh=$(render "$PS2" SESSION_DATA_DIR="$DS")
report "47% 63%" "$(pcts "$seg_fresh")" \
    "seg: a proven-fresh tuple displays the payload's own percentages"
report yes "$(yesno grep -qE '5h: 47% \([0-9]+h[0-9]+m left\), wk: 63% \([0-9]+[dh][0-9]+[hm] left\)' <<<"$seg_fresh")" \
    "seg: ... each paired with a countdown, the weekly in days"

# The 2026-08-05 shape: a session whose very first render can already be
# carrying the outgoing login's windows. Unowned means untrusted, so the
# account's own cache is displayed instead of the payload's numbers.
SIDF="99999999-9999-9999-9999-999999999999"
PSF="$TMP/psf.json"; mkpayload "$SIDF" 0.3 3 4 "$FR" "$WR" "seg" > "$PSF"
seg_foreign=$(render "$PSF" SESSION_DATA_DIR="$DS")
report "47% 63%" "$(pcts "$seg_foreign")" \
    "seg: an unowned first sighting displays the account's cache, not the payload's windows"
report no "$(yesno has "$seg_foreign" '5h: 3%')" "seg: ... so the foreign 5h number never reaches the line"
report no "$(yesno has "$seg_foreign" 'wk: 4%')" "seg: ... nor the foreign weekly one"

# An expired window is flagged, never zeroed. The weekly runs on a fixed
# cadence so it can be stepped forward (marked ~ and ?); the 5h is
# usage-anchored, so its next boundary is unknowable and it says so.
DST="$TMP/dataseg-stale"
PFR=$(( NOW - 7200 )); PWR=$(( NOW - 172800 ))
PSS="$TMP/pss.json"; mkpayload "$SID" 0.1 55 60 "$PFR" "$PWR" "seg" > "$PSS"
seg_stale=$(render "$PSS" SESSION_DATA_DIR="$DST")
report "55%? 60%?" "$(pcts "$seg_stale")" \
    "seg: an expired window keeps its percentage and is marked doubtful"
report yes "$(yesno has "$seg_stale" '5h: 55%? (stale)')" \
    "seg: the usage-anchored 5h window is flagged stale rather than projected"
report yes "$(yesno grep -qE 'wk: 60%\? \(~[0-9]+d[0-9]+h left\)' <<<"$seg_stale")" \
    "seg: the weekly is stepped forward on its fixed cadence and marked ~"
report no "$(yesno has "$seg_stale" '0h0m left')" \
    "seg: ... and neither window counts down to a bare zero"

# No reset timestamp at all is a third state: the percentage is current, the
# countdown is unknown, and nothing is invented for it.
DSN="$TMP/dataseg-noreset"
PSN="$TMP/psn.json"; mkpayload "$SID" 0.1 15 25 0 0 "seg" > "$PSN"
seg_nores=$(render "$PSN" SESSION_DATA_DIR="$DSN")
report "15% 25%" "$(pcts "$seg_nores")" "seg: with no reset timestamp the percentage still renders"
report no "$(yesno has "$seg_nores" 'left)')" "seg: ... with no countdown invented for it"
report no "$(yesno has "$seg_nores" 'stale')"  "seg: ... and no stale marker either"

# A window the payload omits entirely is skipped, not rendered as 0% or -1%.
DSA="$TMP/dataseg-absent"
PSA="$TMP/psa.json"
mkpayload "$SID" 0.1 41 25 "$FR" "$WR" "seg" | jq 'del(.rate_limits.five_hour.used_percentage)' > "$PSA"
seg_absent=$(render "$PSA" SESSION_DATA_DIR="$DSA")
report no  "$(yesno has "$seg_absent" '5h:')"     "seg: a window the payload omits is not rendered at all"
report yes "$(yesno has "$seg_absent" 'wk: 25%')" "seg: ... and the other window still is"

# Owned but not proven fresh: per window, the later reset wins, and each
# percentage travels with its own reset so the pair stays coherent. This is the
# idle pane — replaying an elapsed 5h window while the account has since opened
# a new one — and it must show the new window, not the one it is holding.
DSL="$TMP/dataseg-later"
LFR=$(( NOW + 9000 ))
PL1="$TMP/pl1.json"; mkpayload "$SID" 0.1 10 20 "$FR"  "$WR" "seg" > "$PL1"
PL2="$TMP/pl2.json"; mkpayload "$SID" 0.2 30 40 "$FR"  "$WR" "seg" > "$PL2"
PL3="$TMP/pl3.json"; mkpayload "$SID" 0.3 70 80 "$LFR" "$WR" "seg" > "$PL3"
PL4="$TMP/pl4.json"; mkpayload "$SID" 0.4 71 81 "$LFR" "$WR" "seg" > "$PL4"
render "$PL1" SESSION_DATA_DIR="$DSL" TMUX_PANE=%1 >/dev/null    # pane 1, first sighting
render "$PL2" SESSION_DATA_DIR="$DSL" TMUX_PANE=%1 >/dev/null    # pane 1 owned; cache 30/40 @ FR
render "$PL3" SESSION_DATA_DIR="$DSL" TMUX_PANE=%2 >/dev/null    # pane 2 sees a new 5h window
render "$PL4" SESSION_DATA_DIR="$DSL" TMUX_PANE=%2 >/dev/null    # pane 2 fresh; cache 71/81 @ LFR
report 71 "$(jq -r '.rate_limits.five_hour.used_percentage' "$DSL/last-status.$ACCT.json")" \
    "seg: (fixture) the cache now holds the later 5h window"
report "71% 40%" "$(pcts "$(render "$PL2" SESSION_DATA_DIR="$DSL" TMUX_PANE=%1)")" \
    "seg: an owned pane takes the newer 5h window from the cache and keeps its own weekly"

echo "--- case 24: the credential autosave calls the session beside the statusline ---"

D24="$TMP/data24"
P24="$TMP/p24.json"; mkpayload "$SID" 0.11 41 62 "$FR" "$WR" "autosave" > "$P24"

: > "$CALLS"
render "$P24" SESSION_DATA_DIR="$D24" >/dev/null
report "account save" "$(cat "$CALLS")" \
    "case 24: with no vault entry, the render calls the session beside it with 'account save'"

# A vault entry newer than the live credentials means there is nothing to capture.
: > "$CALLS"
touch "$VAULT/$ACCT.json"
render "$P24" SESSION_DATA_DIR="$D24" >/dev/null
report "" "$(cat "$CALLS")" "case 24: a vault entry newer than .credentials.json calls nothing"

# ... and a login that has since been replaced (a bare /login) is captured again.
: > "$CALLS"
touch -t 202001010000 "$VAULT/$ACCT.json"
render "$P24" SESSION_DATA_DIR="$D24" >/dev/null
report "account save" "$(cat "$CALLS")" "case 24: credentials newer than the vault entry are captured"

# An unknown login has no vault name to write under, so the autosave must not fire.
CFG_UNK="$TMP/cfg-unknown"; mkdir -p "$CFG_UNK"
printf '{}\n' > "$CFG_UNK/.claude.json"
printf '{"claudeAiOauth":{"accessToken":"live-token"}}\n' > "$CFG_UNK/.credentials.json"
: > "$CALLS"
env -i PATH="$PATH" HOME="$FH" TZ=UTC CLAUDE_CONFIG_DIR="$CFG_UNK" \
    SESSION_ACCOUNTS_DIR="$VAULT" SESSION_DATA_DIR="$TMP/data24b" \
    bash "$SHOME/statusline.sh" < "$P24" >/dev/null
report "" "$(cat "$CALLS")" "case 24: an unknown login never calls account save"
report present "$(exists "$TMP/data24b/session-log.tsv")" \
    "case 24: ... and the render still does the rest of its work"

echo "--- case 25: an unreadable lib is a refusal, not a wrong status line ---"

NOLIB="$TMP/shome-nolib"
mkdir -p "$NOLIB/lib"
cp "$SL" "$NOLIB/statusline.sh"
out25=$(env -i PATH="$PATH" HOME="$FH" TZ=UTC CLAUDE_CONFIG_DIR="$CFG" \
        SESSION_DATA_DIR="$TMP/data25" bash "$NOLIB/statusline.sh" < "$P20a" 2>"$TMP/err25")
rc25=$?
report 1 "$rc25" "case 25: a missing lib exits 1"
report "" "$out25" "case 25: ... prints no status line"
report yes "$(yesno test -s "$TMP/err25")" "case 25: ... and says so on stderr"
report yes "$(yesno grep -q 'lib/common.sh' "$TMP/err25")" "case 25: ... naming the file it could not read"
report absent "$(exists "$TMP/data25")" "case 25: ... and writes nothing under the data root"

# The unreadable-file half of the same guard. Root can read a mode-000 file, so
# the case says why it did not run rather than passing for the wrong reason.
UNREAD="$TMP/shome-unreadable"
mkdir -p "$UNREAD/lib"
cp "$SL" "$UNREAD/statusline.sh"
cp "$LIB" "$UNREAD/lib/common.sh"
chmod 000 "$UNREAD/lib/common.sh"
if [ -r "$UNREAD/lib/common.sh" ]; then
    skip "case 25: an unreadable lib" "this user can read a mode-000 file (root?)"
else
    out25b=$(env -i PATH="$PATH" HOME="$FH" TZ=UTC CLAUDE_CONFIG_DIR="$CFG" \
             SESSION_DATA_DIR="$TMP/data25b" bash "$UNREAD/statusline.sh" < "$P20a" 2>"$TMP/err25b")
    rc25b=$?
    report 1 "$rc25b" "case 25: a lib that cannot be read exits 1 as well"
    report "" "$out25b" "case 25: ... printing no status line"
fi
chmod 644 "$UNREAD/lib/common.sh"

echo "--- the data root's .gitignore ---"

# The guard has to be keyed on the FILE, not the directory. Three other paths
# create the data root without writing one — `session --hook` and the rewake
# waiter both mkdir the snapshot dir, and the resume queue mkdirs its parent —
# and a directory-keyed guard then never fires again, so a root that first came
# into existence through a hook stays unignored for good.
DG="$TMP/datagi"
mkdir -p "$DG/sessions"                       # a root as another producer leaves it
report absent "$(exists "$DG/.gitignore")" "gitignore: the fixture starts without one (control)"
render "$P20a" SESSION_DATA_DIR="$DG" >/dev/null
report "*" "$(cat "$DG/.gitignore" 2>/dev/null)" \
    "gitignore: a render writes one into a root another producer created"

# Keyed on non-empty, so a truncated file heals on the next render...
: > "$DG/.gitignore"
render "$P20a" SESSION_DATA_DIR="$DG" >/dev/null
report "*" "$(cat "$DG/.gitignore" 2>/dev/null)" "gitignore: an empty one is rewritten"

# ...but an existing one is left alone rather than rewritten every ten seconds.
printf '*\nSTAMP\n' > "$DG/.gitignore"
render "$P20a" SESSION_DATA_DIR="$DG" >/dev/null
report yes "$(yesno grep -q STAMP "$DG/.gitignore")" \
    "gitignore: a populated one is not rewritten on every render"

echo "--- the entry walk: bounded, and immune to an inherited CDPATH ---"

# A cyclic symlink cannot be exec'd — the kernel refuses to open the chain — so
# the loop is exercised on the shipped bytes directly: extracted by its own
# anchors, seeded with a cyclic path, run under a timeout. The control is the
# same extraction with the bound removed, which must hang; without that, this
# case would pass for any reason at all.
if have timeout; then
    walk=$(sed -n '/while \[ -L "\$_src" \]/,/^done$/p' "$SL")
    report yes "$(yesno has "$walk" 'ls -ld')" "walk: the loop was extracted from the shipped file"
    mkdir -p "$TMP/cyc"
    ln -sfn "$TMP/cyc/b" "$TMP/cyc/a"
    ln -sfn "$TMP/cyc/a" "$TMP/cyc/b"
    { printf 'CDPATH=\n_src=%s\n' "$TMP/cyc/a"; printf '%s\n' "$walk"; } > "$TMP/walk-bounded.sh"
    { printf 'CDPATH=\n_src=%s\n' "$TMP/cyc/a"
      printf '%s\n' "$walk" | sed 's/ && \[ "\$_n" -lt 40 \]//'; } > "$TMP/walk-unbounded.sh"
    timeout 3 bash "$TMP/walk-bounded.sh" >/dev/null 2>&1; rcb=$?
    timeout 3 bash "$TMP/walk-unbounded.sh" >/dev/null 2>&1; rcu=$?
    report no  "$(yesno test "$rcb" = 124)" "walk: a cyclic symlink terminates the walk instead of spinning"
    report yes "$(yesno test "$rcu" = 124)" "walk: ... and without the bound the same input hangs (the control)"
else
    skip "walk: the cycle bound" "no timeout(1) to bound the control with"
fi

# An exported CDPATH makes `cd` resolve a relative directory operand against it
# — and, whenever it uses a CDPATH entry, print the directory it picked. So
# SESSION_HOME becomes a two-line value naming a foreign tree, no lib is found
# at it, and the render dies with no line at all. Loud in the sense that it
# fails rather than lying, but the failure lands on a closed stderr and the
# person just sees a blank status bar. The decoy carries a working lib so the
# case can also assert the foreign one is never the one sourced.
CDR="$TMP/cdroot"
mkdir -p "$CDR/real/shome/lib" "$CDR/decoy/shome/lib"
cp "$SL" "$CDR/real/shome/statusline.sh";  cp "$SDIR"/lib/*.sh "$CDR/real/shome/lib/"
cp "$SL" "$CDR/decoy/shome/statusline.sh"; cp "$SDIR"/lib/*.sh "$CDR/decoy/shome/lib/"
printf '\ntouch "%s/decoy-was-sourced"\n' "$TMP" >> "$CDR/decoy/shome/lib/common.sh"
rm -f "$TMP/decoy-was-sourced"
cd_line=$(cd "$CDR/real" && env -i PATH="$PATH" HOME="$FH" TZ=UTC CDPATH="$CDR/decoy" \
          CLAUDE_CONFIG_DIR="$CFG" SESSION_ACCOUNTS_DIR="$VAULT" SESSION_DATA_DIR="$TMP/datacd" \
          bash shome/statusline.sh < "$P20b")
report absent "$(exists "$TMP/decoy-was-sourced")" \
    "CDPATH: an inherited CDPATH does not resolve SESSION_HOME into a foreign tree"
report yes "$(yesno has "$cd_line" 'tkns')" "CDPATH: ... and the render still produces its line"

echo "--- the multi-login tag ---"

# The tag exists to say "these windows are not your usual login's". It is
# meaningful only against the machine's primary config dir: compared with a
# hardcoded ~/.claude it would be permanently on for anyone whose config lives
# elsewhere, which is every session on this box.
D26="$TMP/data26"
tag_line=$(render "$P20b" SESSION_DATA_DIR="$D26")
report yes "$(yesno endswith "$tag_line" " · ${CFG##*/}")" \
    "tag: a config dir that is not the primary one is tagged with its directory name"
notag_line=$(render "$P20b" SESSION_DATA_DIR="$D26" SESSION_PRIMARY_CFG="$CFG")
report no "$(yesno endswith "$notag_line" " · ${CFG##*/}")" \
    "tag: the primary config dir renders no tag"
report yes "$(yesno grep -q 'tkns' <<<"$notag_line")" "tag: the untagged line is still a status line"

echo "--- the task segment ---"

# The tasksync task the session is on, anchored on a link to its Notion row.
# Fixture: a workspace (the `tasks/.sync` marker is what makes it one), a synced
# task with the real shape of an identity.json, one with a short title, and a
# draft — a folder with a task.md and no identity.json, the case the session-task
# pointer exists for. The payload's cwd is what the render walks, so each case
# sets it; the render walks up from there and reads nothing else.
#
# CROSS-LANGUAGE CONTRACT. `tasks/.sync/session-task.json` is written by
# tasksync's `Store.mark_session_task` (tasksync/tasksync/store.py): one record
# per session id, `{slug, at}`. The render reads `slug`. If that file moves or
# its shape changes, this fixture is the place that has to move with it — the
# pointer cases below are what fail when the two sides disagree.
WS="$TMP/ws"; mkdir -p "$WS/tasks/.sync"
TSLUG="2026-08-26-bias-adjustment-for-incomplete-judging-partial-pooling-acros"
TURL="https://app.notion.com/p/Bias-adjustment-aa000000000000000000000000000000"
SSLUG="2026-08-01-improvements-to-the-app"
DSLUG="2026-09-01-a-fresh-draft"
mkdir -p "$WS/tasks/$TSLUG/notes" "$WS/tasks/$SSLUG" "$WS/tasks/$DSLUG"
jq -n --arg s "$TSLUG" --arg u "$TURL" \
   '{page_id:"aa000000000000000000000000000000", url:$u, slug:$s,
     title:"Bias adjustment for incomplete judging: partial pooling across events, unpaired reviews, late rescoring",
     db_id:"22000000000000000000000000000000", stage:1, last_session:null, relations:{}}' \
   > "$WS/tasks/$TSLUG/identity.json"
jq -n --arg s "$SSLUG" \
   '{page_id:"1a000000000000000000000000000000", url:"https://app.notion.com/p/short", slug:$s,
     title:"Improvements to the app", db_id:"22000000000000000000000000000000", stage:1,
     last_session:null, relations:{}}' > "$WS/tasks/$SSLUG/identity.json"
printf -- '---\nstatus: "Not Started"\n---\n\n# A fresher draft about Zoë’s réunion, whose H1 runs past forty characters\n\nbody\n' \
   > "$WS/tasks/$DSLUG/task.md"
at_cwd() {  # CWD OUT — the case-20 payload with its cwd moved
    mkpayload "$SID" 0.1 41 62 "$FR" "$WR" "task seg" \
        | jq --arg c "$1" '.cwd = $c | .workspace.current_dir = $c' > "$2"
}
pointer() {  # SLUG — what tasksync's mark_session_task writes for $SID
    jq -n --arg k "$SID" --arg s "$1" --argjson t "$NOW" '{($k): {slug: $s, at: $t}}' \
        > "$WS/tasks/.sync/session-task.json"
}
no_pointer() { rm -f "$WS/tasks/.sync/session-task.json"; }
DT="$TMP/datatask"
LINK=$(printf ' · \033]8;;%s\a%s ↗\033]8;;\a' "$TURL" "Bias adjustment for incomplete judging")

# The folder rule: a session whose working directory is inside a task folder is
# on that task, wherever inside it. The title is the row's headline — the part
# before ": " — anchored as an OSC 8 link with the BEL terminator Claude Code's
# own link helpers use, and marked ↗ so a linked title is tellable from a plain one.
no_pointer
PT1="$TMP/pt1.json"; at_cwd "$WS/tasks/$TSLUG/notes" "$PT1"
seg_in=$(render "$PT1" SESSION_DATA_DIR="$DT")
report yes "$(yesno has "$seg_in" "$LINK")" \
    "task: a cwd inside a task folder links the row's headline to its Notion url"
report 1 "$(printf '%s\n' "$seg_in" | wc -l | tr -d ' ')" "task: ... and the render is still one line"
report yes "$(yesno has "$seg_in" "${LINK} · ${CFG##*/}")" \
    "task: ... placed after the rate-limit windows and before the login tag"

# Nothing says which task: the workspace root, no pointer.
PT2="$TMP/pt2.json"; at_cwd "$WS" "$PT2"
seg_none=$(render "$PT2" SESSION_DATA_DIR="$DT")
report no "$(yesno has "$seg_none" ']8;;')" "task: at the workspace root with no pointer, no link"
report no "$(yesno has "$seg_none" 'Bias adjustment')" "task: ... and no title"
report yes "$(yesno has "$seg_none" 'tkns')" "task: ... while the rest of the line renders"

# The pointer: `tasks new` / `tasks log` / adopt record the session's task, so a
# session at the repo root — the usual place — shows it from the moment the row
# or the draft exists, beat or no beat.
pointer "$TSLUG"
seg_ptr=$(render "$PT2" SESSION_DATA_DIR="$DT")
report yes "$(yesno has "$seg_ptr" "$LINK")" \
    "task: the session-task pointer names the task from the workspace root"

# The folder wins over the pointer: being inside a folder is a fact about the
# session now; the pointer is what it last did.
pointer "$DSLUG"
seg_both=$(render "$PT1" SESSION_DATA_DIR="$DT")
report yes "$(yesno has "$seg_both" "$LINK")" "task: a cwd inside a task folder wins over the pointer"
report no  "$(yesno has "$seg_both" 'fresher draft')" "task: ... and the pointer's task is not shown"

# A draft has no identity.json and no row: its task.md H1, clipped, unlinked.
# The clip is by code point (jq), so the accented and curly characters survive a
# C-locale render; the cut lands at a word boundary and drops the trailing comma.
seg_draft=$(render "$PT2" SESSION_DATA_DIR="$DT")
report yes "$(yesno has "$seg_draft" ' · A fresher draft about Zoë’s réunion… · ')" \
    "task: a draft shows its H1, clipped at a word boundary with an ellipsis"
report no "$(yesno has "$seg_draft" ']8;;')" "task: ... with no link, since a draft has no row"
report no "$(yesno has "$seg_draft" '↗')"    "task: ... and no link marker"

# A short title is shown whole, linked.
pointer "$SSLUG"
seg_short=$(render "$PT2" SESSION_DATA_DIR="$DT")
report yes "$(yesno has "$seg_short" "$(printf '\a%s ↗\033]8;;' 'Improvements to the app')")" \
    "task: a title under the clip is shown whole"

# The pointer can outlive its folder, and can be garbage: neither shows anything,
# and neither costs the line.
pointer "2026-01-01-a-folder-that-was-deleted"
seg_gone=$(render "$PT2" SESSION_DATA_DIR="$DT")
report no  "$(yesno has "$seg_gone" 'deleted')" "task: a pointer to a vanished folder shows nothing"
report yes "$(yesno has "$seg_gone" 'tkns')"    "task: ... and the line still renders"
printf 'not json' > "$WS/tasks/.sync/session-task.json"
seg_bad=$(render "$PT2" SESSION_DATA_DIR="$DT")
report yes "$(yesno has "$seg_bad" 'tkns')" "task: a malformed pointer file still renders the line"
report no  "$(yesno has "$seg_bad" ']8;;')" "task: ... with no link invented"

# Outside any workspace nothing is shown: the walk from the cwd is the only way
# to a pointer, and no environment variable stands in for it — not even the one
# an earlier build read (its name is spelled in two pieces so that this file
# itself carries no reference to it).
pointer "$TSLUG"
PT3="$TMP/pt3.json"; at_cwd "$FH" "$PT3"
seg_out=$(render "$PT3" SESSION_DATA_DIR="$DT" "AP""ART_WORKSPACE=$WS")
report no "$(yesno has "$seg_out" ']8;;')" "task: outside any workspace nothing is shown, whatever the environment names"

# The pointer names a folder, never a path: a slug carrying "/" or starting with
# "." must not resolve a folder outside tasks/ — the file is plain JSON on disk,
# and what tasksync never writes a hand edit still can.
mkdir -p "$TMP/outside"
jq -n '{page_id:"2b000000000000000000000000000000", url:"https://elsewhere.example/row", slug:"outside",
        title:"A folder outside tasks", db_id:"d", stage:1, last_session:null, relations:{}}' \
   > "$TMP/outside/identity.json"
pointer "../../outside"
seg_trav=$(render "$PT2" SESSION_DATA_DIR="$DT")
report no "$(yesno has "$seg_trav" 'outside')" "task: a pointer slug carrying a path resolves nothing"
report no "$(yesno has "$seg_trav" 'elsewhere')" "task: ... and links nowhere"
pointer ".sync"
seg_dot=$(render "$PT2" SESSION_DATA_DIR="$DT")
report no "$(yesno has "$seg_dot" ']8;;')" "task: a dot-prefixed pointer slug resolves nothing"

# A title with a line break cannot retarget the link: the url is read before
# the title and the title is flattened, as tasksync flattens it on the way in.
NSLUG="2026-08-02-newline-title"
mkdir -p "$WS/tasks/$NSLUG"
jq -n --arg s "$NSLUG" \
   '{page_id:"3c000000000000000000000000000000", url:"https://app.notion.com/p/real-row", slug:$s,
     title:"Fix the thing\nhttps://evil.example/pwn", db_id:"d", stage:1, last_session:null, relations:{}}' \
   > "$WS/tasks/$NSLUG/identity.json"
pointer "$NSLUG"
seg_nl=$(render "$PT2" SESSION_DATA_DIR="$DT")
report yes "$(yesno has "$seg_nl" "$(printf ']8;;https://app.notion.com/p/real-row\aFix the thing https://evil.example/pwn ↗')")" \
    "task: a title with a line break keeps the row's url and is shown flattened"
report 1 "$(printf '%s\n' "$seg_nl" | wc -l | tr -d ' ')" "task: ... on one line"

# The pointer is per session: another session's record is not this one's task.
jq -n --arg s "$TSLUG" --argjson t "$NOW" '{"99999999-9999-9999-9999-999999999999": {slug: $s, at: $t}}' \
    > "$WS/tasks/.sync/session-task.json"
seg_other=$(render "$PT2" SESSION_DATA_DIR="$DT")
report no "$(yesno has "$seg_other" ']8;;')" "task: another session's pointer is not this session's task"

echo
echo "$pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
