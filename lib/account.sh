# shellcheck shell=bash
# ── 1. header ─────────────────────────────
# Account selection for the session CLI: the policy that decides whether the
# box should move to another login, and which one.
#
# SOURCED, NEVER EXECUTED, beside lib/common.sh and after it. It sets no shell
# options, reads no file, makes no network call, asks no clock and reads no
# global — every input arrives as an argument or on stdin. That is what makes
# the policy testable in-process: the suite sources this file and drives it
# from literals, while `session` itself cannot be sourced at all (sourcing it
# runs it).
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
# The cooldown and probation intervals.

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
# The usage-endpoint probe: ACCT_USAGE_URL, ACCT_USAGE_JQ and acct_probe.

# ── 5. audit log ──────────────────────────
# The switch log's writer and reader: acct_log and acct_log_last.

# ── 6. decision ───────────────────────────
# The decision verb acct_auto, and the notify seam.
