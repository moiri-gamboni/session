# shellcheck shell=bash
# ── 1. header ─────────────────────────────
# Account selection for the session CLI: the policy that decides whether the
# box should move to another login, and which one.
#
# SOURCED, NEVER EXECUTED, beside lib/common.sh and after it. It sets no shell
# options. Section 3, the policy itself, also reads no file, makes no network
# call, asks no clock and reads no global — every input arrives as an argument
# or on stdin, which is what makes the policy testable in-process: the suite
# sources this file and drives it from literals. The sections after it reach
# the vault, the clock and the usage endpoint, and section 6 also spawns
# processes — a locked re-exec of `session` and whatever the notify seam points
# at — so none of them belongs on a hot path. They live here for the same
# reason the policy does: `session` cannot be sourced at all (sourcing it runs
# it), so anything a test has to drive in-process has to sit beside the policy
# rather than in the CLI.
#
# bash 3.2 clean, like the rest of the shipped tree: macOS ships 3.2, and the
# suite's case 1 lints for the constructs it lacks.
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
# "Spent" means at or above a percentage the caller supplies, so the policy is
# testable at any threshold; the decision in section 6 passes ACCT_SPENT_PCT.

# ── 2. constants ──────────────────────────
# Two intervals, and they are deliberately not one. The cooldown bounds
# decision storms box-wide: one decision per quarter hour, whatever fires, not
# one per login (a usage hold bounds only the usage trigger's own retries; see
# _acct_past_cooldown). (The blank-credential refusal is the one caller that applies
# it per login, because its subject is a login rather than the box.) Probation
# is the narrower window in which a switch that has just happened is still
# being judged: while its target is the login now live, another death on that
# login re-decides instead of waiting the cooldown out. Which switches that
# covers is narrower than "the failed ones" — one of acct_swap's failures
# never makes its target live at all — and the decision's own gate in section
# 6 is where the cases are spelled out. Collapsing both intervals into a
# single 300-second value would put that one BELOW this box's measured retry
# cadence of 326-343 s, so the bypass would never engage and a switch that
# needed re-deciding would sit until the next cap death fifteen minutes later.
#
# Neither is a knob. No caller wants a different value, and the "a switch is
# expensive, so make the cooldown tunable" argument was measured and does not
# hold: the median switch costs 1,457 cache-creation tokens.
ACCT_COOLDOWN_S=900
ACCT_PROBATION_S=600

# A window counts as spent at 98%, just short of the cap: the status line asks
# for a decision when a fresh figure reaches it (the usage trigger), so the box
# moves before any turn dies on the cap, and a candidate this close to its cap
# is not worth moving every session onto. A login at 90% of its week still has
# hours of work in it, and switching away from one, or refusing to switch to
# one, would strand that, so this is deliberately not USAGE_WARN_PCT, which
# decides when a session is warned, not when a login is out.
ACCT_SPENT_PCT=98

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
    # rungs 1 and 2 every window that counts is below the threshold, which is
    # never above 100.
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

_acct_probe_blank() {  # STATE [SCOPED_ROWS] -> a row whose every figure is unknown
  printf '%s\t-1\t-1\t-1\t0\t0\t0\t%s\n' "$1" "${2:-0}"
}

# One login's windows, straight from the endpoint. The reset epochs are
# meaningful ONLY here: the frozen path renders durations and discards Fable's
# reset outright, so a consumer must read a non-good candidate's resets as
# unknown rather than as zero.
#
# A LAPSED access token is never sent, and never refreshed here. A refresh
# goes through Claude Code's own token endpoint, which nothing documents, and
# spends a single-use refresh token: a new pair lost before it lands in the
# vault loses that login until its next /login, and on the live login it would
# rotate the credential every running session holds. The cost is real, not
# nil: the account behind an entry idle past its token's ~8 h life can still be
# spent from another device, and its frozen figures miss that. An entry with
# no readable token at all answers `lapsed` as well: nothing was asked, so
# nothing is known — `dead` would claim the endpoint rejected a token that was
# never sent.
acct_probe() {  # LOGIN VAULTFILE -> state TAB five TAB week TAB fable TAB 5reset TAB wreset TAB freset TAB scoped
  local login="$1" vf="$2" tok c u body code row five week fable r5 rw rf scoped
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
  IFS=$'\t' read -r five week fable r5 rw rf scoped <<<"$row"
  if [ -z "$row" ] || { [ "$five" = -1 ] && [ "$week" = -1 ] && [ "$fable" = -1 ]; }; then
    # The one case worth keeping a body for. This endpoint's shape has already
    # moved once, and a 200 that reads as nothing is the only evidence that
    # would let anyone follow it again.
    mv -f "$body" "$(session_cache_path "$login" probe-body)"
    _acct_probe_blank noshape "${scoped:-0}"
    return 0
  fi
  # The Fable file, from the row just read rather than a second parse of the
  # body. A body with no Fable row with a numeric percent leaves the previous
  # file in place: the endpoint is undocumented, so a row that is missing is
  # not evidence the figure went away.
  if [ "$fable" != -1 ]; then
    printf '{"fable":{"used_percentage":%s,"resets_at":%s}}\n' "$fable" "$rf" > "$c.tmp.$$" \
      && mv -f "$c.tmp.$$" "$c" || rm -f "$c.tmp.$$"
  fi
  # The general windows too, in the statusline cache's shape, for `session
  # account` to list when they are the newer reading (acct_row): a login that is
  # not live has a statusline cache frozen at the switch, and listed from it a
  # capped login shows the headroom it had then. A window the body did not
  # carry is left out, which lists as n/a.
  if [ "$five" != -1 ] || [ "$week" != -1 ]; then
    u=$(session_cache_path "$login" usage)
    jq -nc --argjson f "$five" --argjson w "$week" --argjson r5 "$r5" --argjson rw "$rw" '
        {rate_limits: ((if $f >= 0 then {five_hour: {used_percentage: $f, resets_at: $r5}} else {} end)
                     + (if $w >= 0 then {seven_day: {used_percentage: $w, resets_at: $rw}} else {} end))}' \
        > "$u.tmp.$$" && mv -f "$u.tmp.$$" "$u" || rm -f "$u.tmp.$$"
  fi
  # Dropped the moment a body reads again, so the file is always the last
  # response this login gave that nothing could be read from, never an older
  # one — which is the only version of that statement worth acting on.
  rm -f "$body" "$(session_cache_path "$login" probe-body)"
  printf 'good\t%s\n' "$row"
}

# Which account an access token belongs to, from the endpoint Claude Code's own
# startup profile fetch reads ("oauth populate" in the 2.1.304 bundle; called
# by hand 2026-10-20). Undocumented:
#
#   GET https://api.anthropic.com/api/oauth/profile, bearer token on curl's
#   STDIN, Content-Type: application/json, Cache-Control: no-cache
#   200  {account:{uuid, email, full_name, display_name, …},
#         organization:{uuid, name, organization_type, seat_tier, …},
#         application:{…}}; organization_type takes the identity's own
#         vocabulary (claude_max, claude_pro, claude_team, claude_enterprise)
#   401  {"type":"error","error":{"type":"authentication_error",…}} for an
#        invalid token and for none
#
# Prints {"oauthAccount":{…},"end":N,"plan":"…"}: the account as an identity
# in .claude.json's own field names, so session_login_read names it like any
# identity file, beside the sign-in end and plan of the very credential that
# was sent, so a record written from it cannot pair one sign-in with another's
# account. Non-zero, printing nothing, when nothing was asked or nothing
# answered: no curl, a lapsed token (never sent, as in acct_probe, and for the
# same reasons), any status but 200, or a 200 with no account email, whose body
# is kept as profile-body.json for the next person to follow the shape.
ACCT_PROFILE_URL=https://api.anthropic.com/api/oauth/profile
acct_profile() {  # CREDENTIALS -> {"oauthAccount":{…},"end":N,"plan":"…"}, or non-zero
  local tok end plan body code
  command -v curl >/dev/null 2>&1 || return 1
  # Split on the unit separator, and a blank token refused before the split:
  # tab is IFS whitespace, so an empty first field would collapse and the end
  # would be sent as the token.
  IFS=$'\037' read -r tok end plan < <(jq -r --argjson now "$(now_epoch)" '
      .claudeAiOauth // {}
      | select((.expiresAt // 0) / 1000 > $now + 60 and (.accessToken // "") != "")
      | [.accessToken, (.refreshTokenExpiresAt // 0 | floor | tostring), (.subscriptionType // "")]
      | join("\u001f")' "$1" 2>/dev/null)
  [ -n "${tok:-}" ] || return 1
  body="$SESSION_DATA/.profile.$$"
  code=$(printf 'header = "Authorization: Bearer %s"\n' "$tok" \
         | curl -s -m 5 -K - -H 'Content-Type: application/json' -H 'Cache-Control: no-cache' \
                -o "$body" -w '%{http_code}' "$ACCT_PROFILE_URL")
  [ "$code" = 200 ] || { rm -f "$body"; return 1; }
  # Not $end: `end` is a keyword jq 1.6 refuses as a variable name.
  jq -ce --argjson e "${end:-0}" --arg plan "${plan:-}" '
      {oauthAccount: ({accountUuid: .account.uuid, emailAddress: .account.email,
                       organizationUuid: .organization.uuid, organizationName: .organization.name,
                       organizationType: .organization.organization_type,
                       seatTier: .organization.seat_tier, displayName: .account.display_name}
                      | with_entries(select(.value != null))),
       end: $e, plan: $plan}
      | select((.oauthAccount.emailAddress // "") != "")' "$body" 2>/dev/null \
    || { mv -f "$body" "$SESSION_DATA/profile-body.json"; return 1; }
  rm -f "$body" "$SESSION_DATA/profile-body.json"
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
# `$SESSION_DATA/switch-log.tsv` (bar a cooldown hold on the usage trigger,
# which is not logged: section 6), and that file is also the switcher's only
# control state: the cooldown and the post-switch probation both read it
# back.
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
#   trigger  cap | auth | usage | manual
#   figures  `login=5h/wk/fb` joined by `;`, `*` marking a probe-fresh figure
#   detail   a `k=v;` bag over sid= http= tier= next_eligible= scoped= notify=.
#            There is no `recov=`: the waiter's own sleep target already is the
#            recovery time.
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
# the same as the newest row. A refusal and a cooldown hold carry no `scoped=`,
# so `doctor`, which reports the probe's scoped-row count from here, would read
# it as absent after either if it looked only at the newest row.
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
# `session account auto` — the one place that decides by itself which login the
# box runs on, and a verb a human can run, which is what makes the automatic
# path debuggable: same code, same output, on demand.
#
# Exit codes: 0 switched · 3 held · 4 refused · 5 error. NEVER 1, because 1 is
# what flock(1) reports when the lock is held (the perl fallback reports 75).
# A caller has to be able to tell "somebody else is deciding" from "a decision
# was taken", so no decision outcome may wear a busy code. Both busy codes mean
# busy; neither is a decision.
#
# THE LOCK IS TAKEN HERE, and what it covers runs as a child process. lock_run
# EXECS its command, so a lock cannot be held across a shell function — and
# putting the swap under it is the point: acct_swap's temp files are keyed by
# $$, which is the parent's pid inside a subshell, so two concurrent swaps would
# collide on one temp name.
#
# THE NOTIFICATION IS FIRED AFTER THE LOCKED SECTION ENDS, NEVER INSIDE IT.
# Because lock_run execs, the command and anything it backgrounds inherit the
# lock descriptor and hold the lock for as long as they live; closing the
# child's stdin does not release it, since the lock is not on stdin and the
# descriptor number cannot be known from inside. Both measured, on both
# backends. A notifier that hung would otherwise pin the decision lock for
# ever — the failure `timeout` was reached for, with a tool this tree uses
# nowhere and macOS does not ship at all. Firing it in the parent, after the
# child has exited, neither holds the lock nor delays the decision.
#
# This section reads globals (SESSION_AUTO_SWITCH, SESSION_SWITCH_NOTIFY,
# SESSION_HOME) and calls into `session` for the vault and the
# swap, so unlike section 3 it runs only inside a `session` process. Three of
# them reach it: a human typing the verb, the auto-resume waiter on a cap or
# auth death, and the status line when a fresh figure for the live login
# reaches ACCT_SPENT_PCT. The last two have no one reading stderr — on the
# waiter's path stderr is the wake channel, and the status line runs the
# decision detached with its output discarded — which is why every diagnostic
# here goes to the audit row and the k=v output instead.

# The decision's mutex, resolved per call like the log's path so both follow
# SESSION_DATA wherever a caller puts it.
acct_lock_file() { printf '%s\n' "$SESSION_DATA/switch.lock"; }

# Whether a vault entry may be switched TO at all. Five shapes are excluded:
# no token to authenticate with and an expiry of zero (the 2026-09-15 blank,
# where every key was present and the object held nothing), both on this
# machine's record, a sign-in that has ended (acct_signin_ended), the live seat
# under another name (acct_same_seat), and a credential that is the one already
# live.
#
# The last is the mis-filed entry the swap's two-file window can produce: the
# statusline's autosave, which is under no lock, files the incoming credential
# under the outgoing login's name. Excluding the live login by NAME does not
# catch it — the name is the other login's — and neither does the swap, whose
# post-condition compares what it installed against THE ENTRY's credential, so
# a credential that never moved reads back as a successful switch. The box would
# then announce a move and wake a capped session onto the login it never left,
# which is not recoverable the way the mis-filed entry itself is.
#
# On the ACCESS TOKEN and not on the whole claudeAiOauth object: the token is
# what authenticates, so an entry holding the live one moves the box nowhere
# whatever else it carries, and the live file holds a refresh token an entry
# saved from an earlier state of it may not. The live credentials file is
# passed in, and the live identity read where session_identity_file finds it
# (the live login's vault entry while a session has written another
# organisation into .claude.json, which would otherwise screen out the very
# seat the box should move to), because whether an entry may be switched to is
# a question about the entry and the machine's current state together.
acct_entry_ok() {  # VAULTFILE LIVE_CREDENTIALS
  acct_token_ok "$1" || return 1
  jq -e '(.claudeAiOauth.expiresAt // 0) != 0' "$1" >/dev/null 2>&1 || return 1
  ! acct_signin_ended "$1" || return 1
  ! acct_same_seat "$1" "$(session_identity_file)" || return 1
  ! acct_holds_live_token "$1" "$2"
}
# Whether a vault entry is the live account in the live organisation filed under
# another name. Limits belong to the seat, so switching to it gains nothing, and
# its credential is usually an older copy of the live one, whose refresh token
# the live copy's renewal has already spent: installed, Claude Code blanks it
# and every session dies on authentication. An identity missing either field never matches.
acct_same_seat() {  # VAULTFILE LIVE_IDENTITY
  jq -e --slurpfile j "$2" '
      (.oauthAccount // {}) as $v | ($j[0].oauthAccount // {}) as $l
      | ($v.organizationUuid // "") != "" and ($v.emailAddress // "") != ""
        and $v.organizationUuid == $l.organizationUuid
        and $v.emailAddress == $l.emailAddress' "$1" >/dev/null 2>&1
}
# Whether a credential can no longer be renewed: its access token has expired
# and so has its refresh token. `refreshTokenExpiresAt` is a fixed end set at
# /login that renewal does not move (every vault entry and its .history copies
# carry the same value across weeks of renewals), and on 2026-09-29 a login
# 3.5 h past it had its renewal fail and its live access token blanked. Such an
# entry installed only reproduces that blank. An absent or zero end is unknown
# and never reads as ended.
acct_signin_ended() {  # CREDENTIALS_OR_VAULTFILE
  jq -e --argjson now "$(now_epoch)" '
      (.claudeAiOauth.refreshTokenExpiresAt // 0) as $r
      | $r > 0 and $r / 1000 <= $now
        and (.claudeAiOauth.expiresAt // 0) / 1000 <= $now' "$1" >/dev/null 2>&1
}
# Whether a vault entry holds the access token the credentials file has
# installed — the one test behind both the screening above and doctor's
# `vault` line, so the two cannot disagree about which entry is skipped.
# Compared as a boolean, so no token is rendered.
acct_holds_live_token() {  # VAULTFILE LIVE_CREDENTIALS
  jq -e --slurpfile c "$2" \
     '.claudeAiOauth.accessToken == $c[0].claudeAiOauth.accessToken' "$1" >/dev/null 2>&1
}

# Whether a decision may be taken at all right now.
#
# The cooldown is measured against the newest row THIS VERB wrote, which is
# neither a refusal of a save nor a cooldown hold. A refusal belongs to another
# producer, and the blank-credential outage that produces a run of them is
# exactly when an authentication death most needs a decision; a cooldown hold
# is not a decision either, and counting it would slide the window forward on
# every retry, so the cooldown would never end while anything kept asking.
#
# A hold the usage trigger left bounds only the usage trigger's own retries.
# It was taken while every session was still running; a cap or authentication
# death after it has a stopped session behind it, and waiting out a quarter
# hour on a hold that predates the death would leave that session asleep until
# a reset rather than moved.
#
# The cooldown is also about the login that decision left live: the target of
# a switch, the login a hold stayed on, either one for a failed swap. Once the
# live login is another — a `session account use` or a `/login` since — that
# decision concluded nothing about it, and holding would leave a login the
# switcher never chose to die on its cap unmoved for the rest of the quarter
# hour (2026-10-19: a switch off a 98% login, a manual switch back onto it, and
# every death on it four minutes later held).
_acct_past_cooldown() {  # NOW LIVE TRIGGER
  local now="$1" live="$2" trigger="$3" f last lev lfrom lto lastsw
  f=$(acct_log_file)
  [ -s "$f" ] || return 0
  # Fields never empty (acct_log writes `-`), so `read` on tabs is safe here.
  IFS=$'\t' read -r last lev lfrom lto < <(awk -F'\t' -v t="$trigger" '
    $2 == "refuse" || $6 == "cooldown" { next }
    t != "usage" && $2 == "hold" && $5 == "usage" { next }
    { row = ($1 + 0) "\t" $2 "\t" $3 "\t" $4 }
    END { print (row == "" ? "0\t-\t-\t-" : row) }' "$f")
  { [ "${last:-0}" -gt 0 ] && [ $(( now - last )) -lt "$ACCT_COOLDOWN_S" ]; } || return 0
  case "$lev" in
    switch) [ "$live" = "$lto" ] || return 0 ;;
    hold)   [ "$live" = "$lfrom" ] || return 0 ;;
    *)      { [ "$live" = "$lfrom" ] || [ "$live" = "$lto" ]; } || return 0 ;;
  esac
  # Probation: a switch that has just happened is still being judged. While its
  # target is the login now live, another death on that login re-decides rather
  # than waiting the cooldown out. That covers a switch that landed and one
  # whose credential did not — acct_swap writes .claude.json before it discovers
  # the installed credential is not the entry's — but NOT one whose credentials
  # write failed outright, which returns before .claude.json is touched, so the
  # target never becomes live and that failure waits the cooldown out. The
  # ladder bounds what the bypass can cost: every move climbs it.
  lastsw=$(awk -F'\t' -v l="$live" \
             '($2 == "switch" || $2 == "fail") && $4 == l { ts = $1 } END { print ts + 0 }' "$f")
  [ "$lastsw" -gt 0 ] && [ $(( now - lastsw )) -lt "$ACCT_PROBATION_S" ]
}

# The six k=v lines every outcome prints, in one place so no arm can invent a
# key or drop one: two later consumers read this output rather than the log.
_acct_say() {  # EV FROM TO REASON TIER NEXT_ELIGIBLE
  printf 'ev=%s\nfrom=%s\nto=%s\nreason=%s\ntier=%s\nnext_eligible_at=%s\n' \
    "$1" "${2:--}" "${3:--}" "$4" "${5:--}" "${6:--}"
}
_acct_out_val() {  # KEY OUTPUT -> the value of that k=v line
  printf '%s\n' "$2" | awk -F= -v k="$1" '$1 == k { print substr($0, length(k) + 2); exit }'
}

# One window figure as the audit log spells it: a dash for a figure nothing
# knows, never the -1 sentinel with a slash beside it.
_acct_fig() { case "$1" in -1) printf -- '-' ;; *) printf '%s' "$1" ;; esac; }

# What a human is told when the box moved under them. The tier is in the
# sentence because a tier-1 target buys every model except Fable, and a session
# that resumes on Fable would die on the same cap again. The sentence does not
# say the target SPENT its Fable window: an unreadable one reaches tier 1 too,
# by the fail-closed rule, and naming a figure nobody measured would be worse
# than naming none.
_acct_switch_msg() {  # FROM TO TIER
  local rest="It has headroom on every rate-limit window."
  [ "$3" = 1 ] && rest="It serves every model except Fable, so a session resuming on Fable has to continue on another model."
  printf 'session: the live login switched from %s to %s. %s' "$1" "$2" "$rest"
}

# Why the box left the live login, in the words a running session shows beside
# the switch (the marker's reason= line, acct_swap in `session`): the credential
# the endpoint refused or that holds no token, else the windows it had spent.
_acct_switch_why() {  # LIVESTATE LIVEBLOCKS
  local w="$2"
  case "$1" in
    dead)  printf 'credential rejected'; return ;;
    blank) printf 'credential blank'; return ;;
  esac
  w=${w//week/weekly}; w=${w//fable/Fable}; w=${w//,/, }
  case "$w" in *,*) printf '%s limits' "$w" ;; *) printf '%s limit' "$w" ;; esac
}

# When the earliest rejected candidate would stand ABOVE the live login — the
# one piece of genuinely new information a hold carries, and what lets a waiter
# sleep to a time something changes rather than to a reset that changes nothing.
#
# Per candidate: the windows that must clear for it to exceed the live tier
# (both general windows when the live login serves nothing, all three when it
# only lacks Fable), the latest of their resets, and then the earliest of those
# across candidates. Only a probed candidate can contribute — the frozen path
# renders durations and drops Fable's reset outright, so a candidate read from
# a cache has no epoch to offer and a dash is the honest answer.
_acct_next_eligible() {  # LIVETIER  (candidate rows on stdin) -> an epoch, or -
  local livetier="$1" name blocks r5 rw rf state best='-' latest unknown w r
  # Nothing stands above tier 2, so no reset lifts anything past it.
  [ "$livetier" -ge 2 ] && { printf -- '-\n'; return 0; }
  while IFS=$'\t' read -r name blocks r5 rw rf state; do
    [ "$state" = good ] || continue
    latest=0; unknown=0
    for w in 5h week fable; do
      # Clearing Fable only promotes a candidate once the live login already
      # serves every other model; below that it changes no tier.
      [ "$w" = fable ] && [ "$livetier" = 0 ] && continue
      case ",$blocks," in *",$w,"*) ;; *) continue ;; esac
      case "$w" in 5h) r=$r5 ;; week) r=$rw ;; *) r=$rf ;; esac
      [ "$r" -gt 0 ] || { unknown=1; break; }
      [ "$r" -gt "$latest" ] && latest=$r
    done
    { [ "$unknown" = 0 ] && [ "$latest" -gt 0 ]; } || continue
    if [ "$best" = '-' ] || [ "$latest" -lt "$best" ]; then best=$latest; fi
  done
  printf '%s\n' "$best"
}

# The decision itself, already under the lock.
_acct_decide() {  # TRIGGER SID DRY
  local trigger="$1" sid="$2" dry="$3"
  local thr cfg live now probeout n=0 vf name fresh star fg
  local state f5 wk fb r5 rw rf sc blocks ctier
  local livestate='-' livetier=2 liveblocks='-' scoped='-'
  local rankrows="" cinfo="" candmap="" figures="" table=""
  local winner="" winvf="" wblocks wintier to='-' tier ev reason nexteli='-'
  local notify fired detail tab=$'\t' nl=$'\n'

  # ── the refusals: nothing read, nothing written, nothing asked ──
  case "${SESSION_AUTO_SWITCH:-on}" in
    on) ;;
    off) _acct_say refuse - - off - -; return 4 ;;
    *)  echo "session account auto: SESSION_AUTO_SWITCH is '${SESSION_AUTO_SWITCH:-}' — it takes on or off" >&2
        _acct_say refuse - - bad-mode - -; return 4 ;;
  esac
  thr=$ACCT_SPENT_PCT
  cfg=$(acct_cfg)
  [ -s "$cfg/.credentials.json" ] || {
    echo "session account auto: this Claude Code stores credentials in the macOS Keychain, which this build cannot swap; see README.md" >&2
    _acct_say refuse - - no-credentials - -; return 4; }
  live=$(acct_live_login)
  [ "$(acct_paths | grep -c . || true)" -ge 2 ] || {
    _acct_say refuse "$live" - too-few-logins - -; return 4; }

  # ── no state, no switch ──
  # Re-checked inside the lock, because this is the process that swaps: a root
  # that went read-only since the caller looked (the btrfs flip on this box's
  # record) would otherwise move the login and leave no row saying why.
  [ -w "$SESSION_DATA" ] || { _acct_say hold "$live" - not-writable - -; return 3; }

  # ── the cooldown, box-wide ──
  now=$(now_epoch)
  if ! _acct_past_cooldown "$now" "$live" "$trigger"; then
    ev=hold
    # A usage trigger held here leaves no row: nothing died, and the status
    # line asks again on the next fresh figure, so a row per ask would only
    # bury the decisions.
    if [ "$dry" = 1 ]; then ev='dry-run'
    elif [ "$trigger" != usage ]; then acct_log hold "$live" - "$trigger" cooldown - "sid=$sid"; fi
    _acct_say "$ev" "$live" - cooldown - -
    return 3
  fi

  # ── the candidates, screened before any token of theirs is sent ──
  while IFS= read -r vf; do
    [ -n "$vf" ] || continue
    name=$(acct_name_of "$vf")
    # The live login is not a candidate: installing a second copy of the
    # credential already in place buys nothing, and probing it would ask the
    # endpoint twice under one identity.
    { [ -n "$name" ] && [ "$name" != "$live" ]; } || continue
    acct_entry_ok "$vf" "$cfg/.credentials.json" || continue
    candmap="$candmap$name$tab$vf$nl"
  done < <(acct_paths)

  # A dry run probes like any decision, and so refreshes the per-login caches
  # exactly as `session account list` does; what it never does is swap or
  # notify.
  probeout=$(
    # The LIVE credentials file, never the vault's copy of it: that is the token
    # actually serving requests, so its windows are the ones being decided on.
    printf '%s\t%s\n' "$live" "$(acct_probe "$live" "$cfg/.credentials.json")"
    printf '%s' "$candmap" | cut -f2 | acct_probe_all
  )

  while IFS=$'\t' read -r name state f5 wk fb r5 rw rf sc; do
    [ -n "$name" ] || continue
    n=$(( n + 1 ))
    # A blank live token probes `lapsed` (nothing is sent), but unlike an
    # unreadable login it is known to serve nothing: Claude Code writes it when
    # a renewal fails. Read as the network-down case, the live login would be
    # ranked on its pre-outage cache (often tier 2), and nothing could stand
    # strictly above it.
    [ "$n" = 1 ] && [ "$state" = lapsed ] && acct_token_blank "$cfg/.credentials.json" && state=blank
    if [ "$state" = good ]; then
      fresh=probe; star='*'
      if [ "$scoped" = - ] || [ "$sc" -gt "$scoped" ]; then scoped=$sc; fi
    else
      fresh=frozen; star=''
      # A credential the endpoint REJECTED, or a live one with no token at all,
      # gets no frozen fallback. Its cached
      # figures may look excellent, and ranking a dead credential on them is
      # precisely how one goes live.
      if [ "$state" != dead ] && [ "$state" != blank ]; then
        IFS=$'\t' read -r f5 _ wk _ fb _ <<<"$(acct_row "$name")"
        f5=$(acct_num "$f5"); wk=$(acct_num "$wk"); fb=$(acct_num "$fb")
      fi
      r5=0; rw=0; rf=0
    fi
    fg="$(_acct_fig "$f5")/$(_acct_fig "$wk")/$(_acct_fig "$fb")"
    figures="${figures:+$figures;}$name=$fg$star"
    if [ "$n" = 1 ]; then
      livestate=$state
      if [ "$state" = dead ] || [ "$state" = blank ]; then
        # The token serving every request is rejected or gone, so this login
        # serves nothing whatever a cache from before still says. This is the
        # authentication-failure case, and it is the one the record shows is
        # worth the whole feature.
        liveblocks=5h,week,fable
      else
        # UNKNOWN_BLOCKS=0: a live login that is merely unreadable is the
        # network-down case, and must not read as blocked — that is exactly
        # when the box most needs another login.
        liveblocks=$(acct_blocked "$thr" "$f5" "$wk" "$fb" 0)
      fi
      livetier=$(acct_tier "$liveblocks")
      table="live=$name/$livetier/$fresh/$fg$nl"
    else
      # UNKNOWN_BLOCKS=1: everything ranked here is a candidate, so an unknown
      # general window fails it closed and an unknown Fable caps it at tier 1.
      blocks=$(acct_blocked "$thr" "$f5" "$wk" "$fb" 1)
      ctier=$(acct_tier "$blocks")
      rankrows="$rankrows$name$tab$fresh$tab$f5$tab$wk$tab$fb$nl"
      cinfo="$cinfo$name$tab$blocks$tab$r5$tab$rw$tab$rf$tab$state$nl"
      table="${table}cand=$name/$ctier/$fresh/$fg$nl"
    fi
  done <<<"$probeout"

  # ── the live login's tier, then the best thing standing above it ──
  # Rank first and admit once: the winner carries the highest tier of any row,
  # so if it is inadmissible no candidate is.
  winner=$(printf '%s' "$rankrows" | acct_rank "$thr")
  if [ -n "$winner" ]; then
    wblocks=$(printf '%s' "$cinfo" | awk -F'\t' -v l="$winner" '$1 == l { print $2; exit }')
    # On the usage trigger the live login is at ACCT_SPENT_PCT, not dead, and
    # still serves every model it served, Fable included. A move onto a login
    # without Fable would stop every Fable session with nothing telling it to
    # change model, so that move waits for the cap death, whose wake-up says so.
    if acct_admissible "$wblocks" "$liveblocks" \
       && { [ "$trigger" != usage ] || [ "$(acct_tier "$wblocks")" = 2 ]; }; then
      to=$winner
      wintier=$(acct_tier "$wblocks")
      winvf=$(printf '%s' "$candmap" | awk -F'\t' -v l="$winner" '$1 == l { print $2; exit }')
    fi
  fi

  if [ "$livestate" = good ] && [ "$livetier" = 2 ]; then
    # Verified clean on every window: the death was transient and moving buys
    # nothing. Only a 200 says this — an unreadable login does not.
    ev=hold; reason='live-clean'; tier=$livetier; to='-'
  elif [ "$to" = '-' ]; then
    ev=hold; reason='no-candidate'; tier=$livetier
    nexteli=$(printf '%s' "$cinfo" | _acct_next_eligible "$livetier")
  elif [ "$dry" = 1 ]; then
    ev=hold; reason=climbed; tier=$wintier
  else
    tier=$wintier
    acct_swap "$winvf" "$live" "$(_acct_switch_why "$livestate" "$liveblocks")"
    case $? in
      0) ev=switch; reason=climbed ;;
      1) ev=fail; reason='swap-write-failed'; tier=$livetier ;;
      # The identity file already names the incoming login here while the
      # credential that landed is somebody else's, so nothing downstream may
      # read the live login name back as evidence of what happened.
      2) ev=fail; reason='swap-not-observed'; tier=$livetier ;;
      # Claude Code's lock stayed held for the whole wait. Nothing was written,
      # so like a failed write this waits out the cooldown rather than
      # starting a probation.
      4) ev=fail; reason='swap-locked'; tier=$livetier ;;
      # Unreachable: the candidate screening above (acct_entry_ok) already
      # refuses an entry that cannot authenticate. Reaching it means the
      # screening was skipped.
      *) ev=fail; reason='swap-refused'; tier=$livetier ;;
    esac
  fi
  # A dry run reaches no arm but those three, all of which hold.
  [ "$dry" = 1 ] && ev='dry-run'

  # ── one row, and the seam armed for the parent to fire ──
  notify="${SESSION_SWITCH_NOTIFY:-}"
  fired=off
  [ -n "$notify" ] && [ -x "$notify" ] && fired=sent
  detail="sid=$sid;http=$livestate;tier=$tier;scoped=$scoped"
  case "$ev" in
    # next_eligible is carried by holds alone and notify by switches alone: a
    # reader takes each from the newest row that carries it, so a row stating a
    # key it never computed would overwrite one that did.
    switch) detail="$detail;notify=$fired" ;;
    hold)   detail="$detail;next_eligible=$nexteli" ;;
  esac
  [ "$dry" = 1 ] || acct_log "$ev" "$live" "$to" "$trigger" "$reason" "$figures" "$detail"
  [ "$dry" = 1 ] && printf '%s' "$table"
  _acct_say "$ev" "$live" "$to" "$reason" "$tier" "$nexteli"
  case "$ev" in
    switch)       return 0 ;;
    hold|dry-run) return 3 ;;
    *)            return 5 ;;
  esac
}

acct_auto() {  # [--trigger cap|auth|usage|manual] [--sid SID] [--dry-run]
  local trigger=manual sid=- dry=0 locked=0 dryflag="" out rc notify msg
  while [ $# -gt 0 ]; do
    case "$1" in
      --trigger) shift; trigger="${1:-}" ;;
      --sid)     shift; sid="${1:-}" ;;
      --dry-run) dry=1 ;;
      # How the locked child is entered, and deliberately not in the help: a
      # decision taken outside the lock is what the lock exists to prevent.
      --locked)  locked=1 ;;
      *) echo "session account auto: unknown option '$1'" >&2
         _acct_say fail - - bad-option - -; return 5 ;;
    esac
    shift
  done
  case "$trigger" in
    cap|auth|usage|manual) ;;
    *) echo "session account auto: --trigger takes cap, auth, usage or manual, not '$trigger'" >&2
       _acct_say fail - - bad-trigger - -; return 5 ;;
  esac
  [ -n "$sid" ] || sid=-

  [ "$locked" = 1 ] && { _acct_decide "$trigger" "$sid" "$dry"; return $?; }

  # The lock file lives under the data root, and lock_run opening it is the
  # first thing here that touches the filesystem — so a root that cannot hold it
  # has to be caught BEFORE the lock, never in the child that never starts.
  # Measured on both: a root this user cannot write is 66 from either backend,
  # and 73 from flock(1) where the filesystem is read-only rather than the
  # directory unwritable — none of them a decision, and flock(1) prints to
  # stderr besides. The hold below is an outcome a caller can act on and report.
  mkdir -p "$SESSION_DATA" 2>/dev/null
  [ -w "$SESSION_DATA" ] || {
    _acct_say hold "$(acct_live_login)" - not-writable - -; return 3; }

  [ "$dry" = 1 ] && dryflag=--dry-run
  # shellcheck disable=SC2086  # dryflag is one word or none, never a path
  out=$(lock_run "$(acct_lock_file)" bash "$SESSION_HOME/session" account auto \
          --locked --trigger "$trigger" --sid "$sid" $dryflag)
  rc=$?

  # A lock file that could not be opened, which is not a lock somebody holds:
  # busy clears by itself and this does not, so a caller left to fall through on
  # it would retry for ever against a switcher that is off. Said as a hold, the
  # outcome every caller already reads, rather than as an exit code nothing
  # branches on — and with no row, because the reason is that this decision
  # never started, not that one was taken.
  if [ "$rc" = 66 ]; then
    _acct_say hold "$(acct_live_login)" - lock-unopenable - -
    return 3
  fi
  [ -n "$out" ] && printf '%s\n' "$out"

  # The lock died with the child that held it, so the seam can be fired now —
  # and only for a switch. Holds are the normal outcome and announcing them is
  # about nine high-priority pushes a day through a Fable-capped week.
  [ "$(_acct_out_val ev "$out")" = switch ] || return $rc
  notify="${SESSION_SWITCH_NOTIFY:-}"
  [ -n "$notify" ] && [ -x "$notify" ] || return $rc
  msg=$(_acct_switch_msg "$(_acct_out_val from "$out")" "$(_acct_out_val to "$out")" \
                         "$(_acct_out_val tier "$out")")
  ( "$notify" "$msg" >/dev/null 2>&1 & )
  return $rc
}

# ── 7. Claude Code's credential locks ─────
# What Claude Code does around a credential write, read out of the 2.1.301
# binary and watched under strace against a scratch config dir. A lock is a
# directory made with mkdir (npm's proper-lockfile): mkdir failing with EEXIST
# means held; the directory's mtime is the holder's proof of life, touched
# every 5 s by a refresh and every 7.5 s by a storage write; a directory
# untouched for the lock's stale age belongs to a dead holder, and whoever
# finds it removes it and retries. Release is rmdir.
#
#   <config dir>/.oauth_refresh.lock    stale after 60 s. One token refresh
#                                       holds it from reading the refresh token
#                                       to writing the new pair.
#   <config dir, symlinks resolved>.lock  taken straight after, same 60 s. The
#                                       older name for the same exclusion, kept
#                                       for sessions running an older build; a
#                                       refresh that cannot create it goes on.
#   <config dir>/.storage-write.lock    stale after 15 s. Held around every
#                                       read-modify-write of .credentials.json,
#                                       by a refresh and by a sign-in to an MCP
#                                       server alike (their tokens live in the
#                                       same file). Taken inside the other two
#                                       and released first.
#
# A refresh also writes .oauth_refresh.lock.owner (pid, process start, the
# lock's birth time) so a contender can take the lock from a holder whose
# process is gone. A record that does not match the lock's birth time is
# ignored, so a holder that writes none, as this one does, is just waited for.
# A refresh contender gives up after about ten seconds of 1-2 s retries and
# reports the refresh as failed (a storage-write contender, after about seven),
# so a hold has to be short: nothing under these locks waits on the network, and
# the mtime is not kept fresh, so a hold outlasting the stale age would let
# another process in. The holds here are a fraction of a second. There is no
# trap: an interrupt while waiting on the second or third lock leaves the ones
# already taken to go stale, so they block a retry, and the refreshes of
# running sessions, for up to a minute.
#
# Why the swap holds them. A refresh posts the refresh token it read, then
# stores the new pair only if the file still holds that token. A swap landing
# in between is therefore not overwritten, but the outgoing login's refresh
# token has been spent by then, and the vault already holds a copy of the
# token that no longer works. A swap landing between another writer's read and
# its rename is simply lost. Holding the refresh lock means no refresh is in
# flight when the outgoing login is vaulted; holding the storage lock makes the
# swap's read-modify-write atomic against every other writer.
#
# None of this is documented, so re-read it after a Claude Code upgrade: run
# `claude -p x` with CLAUDE_CONFIG_DIR and HOME pointing at a scratch directory
# whose .credentials.json holds a fake expired claudeAiOauth (a refresh token
# the server will refuse), under `strace -f -e trace=mkdir,rmdir,rename`.
#
# Staleness is judged against the real clock, not SESSION_NOW: it compares a
# real mtime with it.

# One lock directory. 0 held; 1 still held by someone else when the wait ran
# out; 2 not creatable here (the parent is missing or not writable).
acct_dir_lock() {  # DIR STALE_SECONDS
  local d="$1" stale="$2" waited=0 m
  while :; do
    mkdir "$d" 2>/dev/null && return 0
    # Not creatable: the parent is missing or not ours. A writable parent means
    # the holder released since the mkdir, and the next try finds it free.
    [ -d "$d" ] || [ -w "${d%/*}" ] || return 2
    # A holder that released between the mkdir and the stat leaves no mtime to
    # read. Read as "not stale" so a stat that keeps failing waits out the
    # bound instead of spinning.
    if m=$(mtime_of "$d") && [ $(( $(date +%s) - m )) -gt "$stale" ] && rmdir "$d" 2>/dev/null; then
      continue
    fi
    [ "$waited" -lt "$SESSION_LOCK_WAIT" ] || return 1
    sleep 1
    waited=$(( waited + 1 ))
  done
}

acct_dir_unlock() { rmdir "$1" 2>/dev/null || true; }
