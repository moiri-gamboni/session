# shellcheck shell=bash
# ── 1. header ─────────────────────────────
# Account selection for the session CLI: the policy that decides whether the
# box should move to another login, and which one.
#
# SOURCED, NEVER EXECUTED, beside lib/common.sh and after it. It sets no shell
# options. Section 3, the policy itself, also reads no file, makes no network
# call, asks no clock and reads no global — every input arrives as an argument
# or on stdin, which is what makes the policy testable in-process: the suite
# sources this file and drives it from literals. The sections after it do reach
# the vault, the clock and the usage endpoint, and they live here for the same
# reason: `session` cannot be sourced at all (sourcing it runs it), so anything
# a test has to drive in-process has to sit beside the policy rather than in
# the CLI.
#
# bash 3.2 clean, like the rest of the shipped tree: macOS ships 3.2 and the
# suite runs a leg under `docker run bash:3.2`.
#
# ── the capability ladder ───────────────────────────────────────────────────
# The three rate-limit windows are not interchangeable. The 5-hour and weekly
# windows gate every model; the Fable weekly gates only Fable. So a login's
# usefulness is a three-level ladder rather than a set of spent windows:
#
#   tier 2  nothing spent            — serves every model
#   tier 1  only Fable spent         — serves every model except Fable, which
#                                      is still a perfectly good login for Opus
#   tier 0  5-hour or weekly spent   — serves nothing, whatever the model
#
# A switch is admissible only when it CLIMBS the ladder. Matching it or
# lowering it is refused, which is also why no dwell timer, hysteresis band or
# anti-ping-pong rule is needed: the login just left sits lower by
# construction. Ranking by percentages alone would authorise moving every
# session on the box for a bigger number rather than for a capability it does
# not have.
#
# ── where the candidate rules live, so they are not applied twice ───────────
# Two rules belong to CANDIDATES and not to `acct_tier`, which is a pure
# function of a block list:
#
#   • an unknown 5-hour or weekly window means tier 0 (fail closed)
#   • an unknown Fable window caps the candidate at tier 1, never 2
#
# Both fall out of `acct_blocked`'s UNKNOWN_BLOCKS argument, and that is the
# only place they are implemented. A caller assessing a CANDIDATE passes
# UNKNOWN_BLOCKS=1; a caller assessing the LIVE login passes 0, because a live
# login that is merely unreadable is the network-down case and must not read
# as blocked — that is exactly when the box most needs to move. `acct_rank`
# ranks candidates only, so it passes 1 itself.
#
# ── the threshold is an argument ────────────────────────────────────────────
# "Spent" means at or above a percentage the caller supplies. It is never read
# from a global here: the caller clamps the warn threshold to 100 (a value
# above 100 is the documented way to silence the usage advisory, and would
# otherwise silently mean "no window is ever blocked") and passes the clamped
# value down, so the clamp has exactly one site.

# ── 2. constants ──────────────────────────
# Two intervals, and they are deliberately not one. The cooldown bounds
# decision storms box-wide: one decision per quarter hour, whatever fires, not
# one per login. (The blank-credential refusal is the one caller that applies
# it per login, because its subject is a login rather than the box.) Probation
# is the narrower window in which a switch that has just happened is still
# being judged — the one job it has is letting a FAILED switch bypass the
# cooldown and re-decide. Collapsing both into a single 300-second value would
# put that interval BELOW this box's measured retry cadence of 326-343 s, so
# the bypass would never engage and a failed switch would sit until the next
# cap death fifteen minutes later.
#
# Neither is a knob. No caller wants a different value, and the "a switch is
# expensive, so make the cooldown tunable" argument was measured and does not
# hold: the median switch costs 1,457 cache-creation tokens.
ACCT_COOLDOWN_S=900
ACCT_PROBATION_S=600

# ── 3. pure selector ──────────────────────

# One cell of the account table, or one figure from the usage endpoint, as an
# integer — or -1 for "not known". Built from `case` and never from arithmetic:
# under `set -u` an arithmetic expansion of `n/a` re-expands it as a variable
# name and kills the whole process, silently, inside a hook.
#
# The spellings are the ones `acct_row` renders (`-` no cache, `n/a` window
# absent, `?` 5-hour reset passed and unknowable, `~0%` reset passed) plus the
# bare integers a probe returns. Anything else — including a fractional
# percentage — reads as unknown rather than being guessed at: every producer in
# this tree truncates a fraction before rendering, so a fraction arriving here
# means a producer changed, and unknown is the reading that fails closed.
acct_num() {  # CELL -> an integer, or -1
  local c="${1:-}"
  # `~0` is a projection, not an unknown: the window's reset has already
  # passed, so the figure is KNOWN to be 0 — which makes that login the best
  # possible candidate. Reading it as the unknown sentinel would make the best
  # candidate inadmissible while every other criterion stayed green.
  case "$c" in '~0'|'~0%') printf '0\n'; return 0 ;; esac
  c=${c%\%}
  case "$c" in
    ''|*[!0-9]*) printf '%s\n' -1 ;;
    *)           printf '%s\n' "$c" ;;
  esac
  return 0
}

# Which of one login's windows are spent, canonically ordered and comma-joined,
# or `-` for none. Inputs may be raw table cells or integers: each goes through
# acct_num, which is idempotent over its own output, so there is one
# normalising step and no arithmetic ever meets a sentinel.
acct_blocked() {  # THRESHOLD FIVE WEEK FABLE UNKNOWN_BLOCKS -> - | 5h[,week][,fable]
  local thr="$1" unk="$5" out=""
  _acct_spent "$thr" "$(acct_num "$2")" "$unk" && out="5h"
  _acct_spent "$thr" "$(acct_num "$3")" "$unk" && out="${out:+$out,}week"
  _acct_spent "$thr" "$(acct_num "$4")" "$unk" && out="${out:+$out,}fable"
  printf '%s\n' "${out:--}"
}
_acct_spent() {  # THRESHOLD VALUE UNKNOWN_BLOCKS
  case "$2" in -1) [ "$3" = 1 ]; return ;; esac
  [ "$2" -ge "$1" ]
}

# The ladder position of a block list. BLOCKS is what acct_blocked printed —
# `-` or a comma-joined subset — and an empty string is read as the same empty
# list `-` spells. Pure in the block list: the unknown-window rules that belong
# to candidates are applied upstream, by the UNKNOWN_BLOCKS argument to
# acct_blocked.
acct_tier() {  # BLOCKS -> 0 | 1 | 2
  case ",${1:--}," in
    *,5h,*|*,week,*) printf '0\n' ;;
    *,fable,*)       printf '1\n' ;;
    *)               printf '2\n' ;;
  esac
}

# The whole switching policy: a candidate is admissible only when it stands
# strictly higher on the ladder than the login in use.
acct_admissible() {  # CAND_BLOCKS LIVE_BLOCKS
  [ "$(acct_tier "${1:--}")" -gt "$(acct_tier "${2:--}")" ]
}

# The best candidate among rows of `login TAB freshness TAB f5 TAB wk TAB fb`
# on stdin, or nothing at all. FRESHNESS is `probe` for a login whose figures
# were just verified against the usage endpoint; every other word means the
# figures are frozen — the login's statusline cache stopped refreshing when the
# box switched away from it.
#
# NO FIELD MAY BE EMPTY — a producer with nothing to say writes `-`, which
# reads as unknown. Tab is IFS whitespace, so `read` strips a leading one and
# merges a run of them: an empty field does not arrive as an empty field, it
# silently shifts every field after it and the wrong login goes live. Same rule
# and same reason as `acct_row`'s six never-empty fields.
#
# Ranking, as one fixed-width key so `LC_ALL=C sort` is the whole comparison:
#
#   1. highest capability tier      — the ladder decides before any percentage
#   2. probe-verified before frozen — a frozen figure can only be older than
#                                     the truth, and usage only rises
#   3. the lowest worst window AMONG THE ONES THE TIER DEPENDS ON — a tier-1
#      login's Fable window is already spent and cannot get worse, so ranking
#      two tier-1 logins on their Fable figures compares two numbers that no
#      longer decide anything
#   4. the C-collated login name, so a tie is broken the same way every time
#
# The winner carries the highest tier of any row, so a caller can rank first
# and test admissibility once: if the winner is inadmissible, no candidate is.
acct_rank() {  # THRESHOLD  (rows on stdin) -> the winning login, or nothing
  local thr="$1" login fresh f5 wk fb tier fkey worst
  while IFS=$'\t' read -r login fresh f5 wk fb; do
    f5=$(acct_num "$f5"); wk=$(acct_num "$wk"); fb=$(acct_num "$fb")
    # UNKNOWN_BLOCKS=1: everything ranked here is a candidate.
    tier=$(acct_tier "$(acct_blocked "$thr" "$f5" "$wk" "$fb" 1)")
    case "$fresh" in probe) fkey=0 ;; *) fkey=1 ;; esac
    # The worst window, over the ones this tier still depends on. The group is
    # zero-padded because the key is compared as bytes: unpadded, 10 would beat
    # 9 on the first digit. Three digits is enough — the tier digit sorts
    # first, so two rows only meet here when they are on the same rung, and on
    # rungs 1 and 2 every window that counts is below the threshold, which the
    # caller has clamped to 100.
    worst=$f5
    [ "$wk" -gt "$worst" ] && worst=$wk
    if [ "$tier" = 2 ]; then
      [ "$fb" -gt "$worst" ] && worst=$fb
    fi
    printf '%d%d%03d\t%s\n' $(( 2 - tier )) "$fkey" "$worst" "$login"
  done | LC_ALL=C sort | awk -F'\t' 'NR == 1 { print $2; exit }'
}

# ── 4. probe ──────────────────────────────
# The usage endpoint is the only way to read a login's rate-limit windows
# WITHOUT being logged into it: the statusline cache refreshes for the login in
# use and no other, so every other login's figures are frozen at the moment the
# box switched away, and a decision taken on them is a decision taken on data
# that can only be older than the truth. Undocumented, observed 2026-09-22:
#
#   GET https://api.anthropic.com/api/oauth/usage
#   anthropic-beta: oauth-2025-04-20, bearer token on curl's STDIN
#   200  a limits[] array of {kind, percent, resets_at, scope} rows, beside the
#        flat five_hour/seven_day pair the endpoint carried before it grew that
#        array — both shapes read here, the array first
#   401  {"type":"error","error":{"type":"authentication_error",…}} for an
#        INVALID token and, word for word bar the message, for an EXPIRED one
#
# ONE FETCHER, not two. acct_probe is also what refreshes fable.<login>.json,
# so the token on stdin, the beta header, the five-second timeout, the lapsed
# token skip, the parallel fan-out and the same-directory temp have a single
# implementation. Two copies of those six properties, each pinned by the suite
# on only one of the copies, is how they drift.
ACCT_USAGE_URL=https://api.anthropic.com/api/oauth/usage

# One pass over the response: the two general windows, Fable's, their resets,
# and how many model-scoped windows the body carried. Integers throughout, -1
# for a percentage the body does not have and 0 for a reset it does not have,
# so no consumer has to tell an absent figure from a zero one.
#
# scoped_rows comes out of the same pass rather than a second traversal, and it
# is the whole of a deliberately deferred guard: the selector looks only at
# Fable, so a SECOND model-scoped window would be spent without anything
# noticing. The count reaches the audit row instead, where a shape change shows
# up the week it happens rather than after a bad switch.
ACCT_USAGE_JQ='
  def num: if type == "number" then floor else -1 end;
  def ep: try ((. // "") | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
               | fromdateiso8601) catch 0;
  (if (.limits | type) == "array" then .limits else [] end) as $l
  | ($l | map(select(.kind == "session"))     | first) as $s
  | ($l | map(select(.kind == "weekly_all"))  | first) as $w
  | ($l | map(select(.kind == "weekly_scoped")))       as $sc
  | ($sc | map(select(((.scope.model.display_name // "")
                       | ascii_downcase | startswith("fable")))) | first) as $f
  | [ (if $s then $s.percent   else .five_hour.utilization end | num),
      (if $w then $w.percent   else .seven_day.utilization end | num),
      ($f.percent | num),
      (if $s then $s.resets_at else .five_hour.resets_at   end | ep),
      (if $w then $w.resets_at else .seven_day.resets_at   end | ep),
      ($f.resets_at | ep),
      ($sc | length) ]
  | @tsv'

# The Fable row alone, in the shape the account table reads back. Kept separate
# from ACCT_USAGE_JQ because it is a FILE FORMAT, not a parse: anything short of
# a Fable row with a numeric percent must yield no output and a non-zero status,
# so the previous figure survives a body that simply does not mention Fable.
ACCT_FABLE_JQ='
  if (.limits | type) != "array" then empty else
    first(.limits[]
          | select(.kind == "weekly_scoped"
                   and ((.scope.model.display_name // "") | ascii_downcase | startswith("fable"))
                   and (.percent | type) == "number"))
    | { fable: { used_percentage: .percent,
                 resets_at: ((.resets_at // "") | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
                             | try fromdateiso8601 catch 0) } }
  end'

_acct_probe_blank() {  # STATE [SCOPED_ROWS] -> a row whose every figure is unknown
  printf '%s\t-1\t-1\t-1\t0\t0\t0\t%s\n' "$1" "${2:-0}"
}

# One login's windows, straight from the endpoint. The reset epochs are
# meaningful ONLY here: the frozen path renders durations and discards Fable's
# reset outright, so a consumer must read a non-good candidate's resets as
# unknown rather than as zero.
#
# A LAPSED access token is never sent. Refreshing it rotates credentials that
# the live login's own sessions may be holding, and nothing needs it: a login's
# figures only move while that login is in use, so its last reading stays as
# right as it was. An entry with no readable token at all answers `lapsed` as
# well: nothing was asked, so nothing is known — `dead` would claim the
# endpoint rejected a token that was never sent.
acct_probe() {  # LOGIN VAULTFILE -> state TAB five TAB week TAB fable TAB 5reset TAB wreset TAB freset TAB scoped
  local login="$1" vf="$2" tok c body code row five week fable scoped
  command -v curl >/dev/null 2>&1 || { _acct_probe_blank nocurl; return 0; }
  tok=$(jq -r --argjson now "$(now_epoch)" '
      select((.claudeAiOauth.expiresAt // 0) / 1000 > $now + 60)
      | .claudeAiOauth.accessToken // empty' "$vf" 2>/dev/null)
  [ -n "$tok" ] || { _acct_probe_blank lapsed; return 0; }
  c=$(session_cache_path "$login" fable)
  body="$c.tmp.$$.body"
  # The token rides stdin (-K -), never argv, where any local user's ps reads
  # it. No -f: the status IS the classification, so an error response has to
  # arrive intact for %{http_code} to report it — that is 000 when the transfer
  # produced no response at all.
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" \
         | curl -s -m 5 -K - -H 'anthropic-beta: oauth-2025-04-20' \
                -o "$body" -w '%{http_code}' "$ACCT_USAGE_URL")
  case "$code" in
    200) ;;
    # An expired token and an invalid one are both 401 and differ only in the
    # message, so the body is never read to decide this.
    401|403) rm -f "$body"; _acct_probe_blank dead; return 0 ;;
    # Everything else, 429 included. A 429 is a 4xx, but this endpoint's rate
    # bucket is selected by User-Agent: reading it as dead would mark healthy
    # logins dead and, worse, mark the LIVE login blocked on every window — and
    # the box would move because it was throttled rather than because it was
    # capped.
    *) rm -f "$body"; _acct_probe_blank unreachable; return 0 ;;
  esac
  row=$(jq -r "$ACCT_USAGE_JQ" "$body" 2>/dev/null)
  IFS=$'\t' read -r five week fable _ _ _ scoped <<<"$row"
  if [ -z "$row" ] || { [ "$five" = -1 ] && [ "$week" = -1 ] && [ "$fable" = -1 ]; }; then
    # The one case worth keeping a body for. This endpoint's shape has already
    # moved once, and a 200 that reads as nothing is the only evidence that
    # would let anyone follow it again.
    mv -f "$body" "$(session_cache_path "$login" probe-body)"
    _acct_probe_blank noshape "${scoped:-0}"
    return 0
  fi
  jq -ce "$ACCT_FABLE_JQ" "$body" > "$c.tmp.$$" && mv -f "$c.tmp.$$" "$c" || rm -f "$c.tmp.$$"
  # Dropped the moment a body reads again, so the file is always the last
  # response this login gave that nothing could be read from, never an older
  # one — which is the only version of that statement worth acting on.
  rm -f "$body" "$(session_cache_path "$login" probe-body)"
  printf 'good\t%s\n' "$row"
}

# Every vaulted login at once: paths on stdin, `login TAB <probe row>` on
# stdout. Parallel because each fetch waits up to five seconds on a network the
# caller is asking about precisely because it may be slow.
#
# Each child writes its own file, keyed by the login name sanitised exactly the
# way session_cache_path sanitises it, and the parent reads them after `wait`.
# Not one shared pipe: interleaved writes produce a row carrying another
# login's figures, and that is a switch to the wrong account rather than a
# crash. Not $$ per child either — it is the same number inside a subshell, so
# it cannot key anything; $BASHPID would, and is bash 4 only.
acct_probe_all() {  # vault paths on stdin -> login TAB state TAB five TAB … per login
  local d vf login key row names="" tab=$'\t' nl=$'\n'
  d="$SESSION_DATA/.probe.$$"
  mkdir -p "$d" || return 1
  while IFS= read -r vf; do
    [ -n "$vf" ] || continue
    login=$(jq -r '.login // .email // empty' "$vf" 2>/dev/null)
    [ -n "$login" ] || continue
    key=${login//[!A-Za-z0-9@._+-]/_}
    names="$names$key$tab$login$nl"
    acct_probe "$login" "$vf" > "$d/$key" </dev/null &
  done
  wait
  printf '%s' "$names" | while IFS=$'\t' read -r key login; do
    row=$(cat "$d/$key" 2>/dev/null)
    # A child that died wrote nothing, and an empty field is not a field: tab is
    # IFS whitespace, so a consumer's `read` would silently shift every figure
    # after it and rank the login on somebody else's windows.
    [ -n "$row" ] || row=$(_acct_probe_blank unreachable)
    printf '%s\t%s\n' "$login" "$row"
  done
  rm -rf "$d"
}

# ── 5. audit log ──────────────────────────
# Every automatic decision about which login the box runs on leaves one row in
# `$SESSION_DATA/switch-log.tsv`, and that file is also the switcher's only
# control state: the cooldown, the failed-switch probation and the recovery of
# `next_eligible_at` by a caller that got no output from the decision child all
# read it back.
#
# 8 columns, never fewer:
#
#   ts · ev · from · to · trigger · reason · figures · detail
#
#   ev       switch | hold | fail | refuse. There is no `dead` event: a
#            credential proved dead is a property of ONE CANDIDATE inside a
#            decision, not a decision of its own, so it belongs in that
#            decision's figures and detail and must not compete with the
#            one-row-per-decision rule.
#   trigger  cap | auth | manual
#   figures  `login=5h/wk/fb` joined by `;`, `*` marking a probe-fresh figure
#   detail   a `k=v;` bag over sid= http= tier= next_eligible= scoped= notify=.
#            There is no `recov=`: recovery_at was cut from the design, and the
#            waiter's own sleep target already is it.
#
# NO FIELD IS EVER EMPTY. The writer substitutes `-` for every empty argument
# rather than trusting its call sites, because a reader that reached for `read`
# would not see an empty field as an empty field: tab is IFS whitespace, so a
# leading one is stripped and a run of them merges into one, silently shifting
# every field after it. Same hazard `acct_row`'s comment names and `acct_rank`'s
# row contract states — one hazard, three owners, and this is the one place
# that can keep it from arising at all. The readers below use `awk -F'\t'` for
# the other half of the same reason.
#
# The file is deliberately exempt from the daily prune: 244 cooldown-surviving
# decisions across the entire two-month record is about 1,500 rows a year
# against a 79 MB store, and they are the only account of why the box moved.

# Resolved per call rather than bound when this file is sourced, so the path
# follows SESSION_DATA wherever a caller has put it.
acct_log_file() { printf '%s\n' "$SESSION_DATA/switch-log.tsv"; }

acct_log() {  # EV FROM TO TRIGGER REASON FIGURES DETAIL -> 0 written, non-zero not
  local row arg
  # A caller with nothing to say for the trailing columns may simply stop; the
  # row still has to be eight wide.
  while [ $# -lt 7 ]; do set -- "$@" '-'; done
  row=$(now_epoch)
  for arg in "$@"; do row="$row"$'\t'"${arg:--}"; done
  # The brace group carries the redirect: a redirect that fails is reported
  # when it is SET UP, so a trailing 2>/dev/null on the same command is too
  # late. An unwritable data root is reported to the caller as a non-zero
  # status — no state means no decision — but never as noise on a hook's
  # stderr.
  { printf '%s\n' "$row" >> "$(acct_log_file)"; } 2>/dev/null
}

acct_log_last() {  # [EV] -> the newest row, or the newest of that event
  local f
  f=$(acct_log_file)
  [ -s "$f" ] || return 1
  awk -F'\t' -v ev="${1:-}" '
    ev == "" || $2 == ev { row = $0; found = 1 }
    END { if (found) { print row; exit 0 } exit 1 }
  ' "$f"
}

# The value of one `k=v` key from the newest row THAT CARRIES IT, which is not
# the same as the newest row. A refusal and a cooldown hold carry neither
# `next_eligible=` nor `scoped=`, and a caller recovering either from the log —
# because the decision child was locked out, or held before it computed
# anything — would read both as absent if it looked only at the newest row.
# A key present with the value `-` IS carried: that is a decision saying it
# computed the figure and found none, which is newer than an older epoch.
acct_log_key() {  # KEY -> the value, or non-zero if no row carries it
  local f
  f=$(acct_log_file)
  [ -s "$f" ] || return 1
  awk -F'\t' -v key="$1" '
    {
      n = split($8, kv, ";")
      for (i = 1; i <= n; i++)
        if (index(kv[i], key "=") == 1) { val = substr(kv[i], length(key) + 2); found = 1 }
    }
    END { if (found) { print val; exit 0 } exit 1 }
  ' "$f"
}

# ── 6. decision ───────────────────────────
# The decision verb acct_auto, and the notify seam.
