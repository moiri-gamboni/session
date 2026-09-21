#!/usr/bin/env bash
# Status line for Claude Code TUI
# Receives JSON on stdin, outputs a single line

# Every path, the umask and the platform layer come from the lib beside this
# script. The walk resolves a symlinked entry point (the usual install puts one
# on PATH) without readlink -f, which is GNU-only. This runs BEFORE stderr is
# closed below, so a broken install says so instead of rendering a line off
# defaults that point at the wrong store.
# CDPATH is cleared first: an exported one makes `cd` resolve a relative
# directory operand against it and PRINT the directory it chose, which would
# make SESSION_HOME a two-line value naming someone else's tree. The bound is
# realpath_of's, for the same reason it has one — a symlink cycle otherwise
# spins here forking four processes an iteration, with nothing ever printed.
CDPATH=
_src="${BASH_SOURCE[0]}"
_n=0
while [ -L "$_src" ] && [ "$_n" -lt 40 ]; do
  _dir=$(cd -P "$(dirname "$_src")" && pwd)
  _src=$(ls -ld "$_src" | sed 's/.*-> //')
  case "$_src" in /*) ;; *) _src="$_dir/$_src";; esac
  _n=$(( _n + 1 ))
done
SESSION_HOME=$(cd -P "$(dirname "$_src")" && pwd)
. "$SESSION_HOME/lib/common.sh" || { echo "statusline: cannot read $SESSION_HOME/lib/common.sh" >&2; exit 1; }

exec 2>/dev/null
input=$(cat)

# Persist the stdin payload for the on-demand `usage` reader.
# The cache is shared across ALL sessions OF THE SAME ACCOUNT — rate-limit
# windows are per-login, so the store is keyed by the login NAME read from the
# session's config dir: the email, plus +<org slug> for a Team or Enterprise
# seat (lib: session_login_read; multi-account via `session account`: one live login;
# the payload itself carries no account field, but the hook inherits the
# session's CLAUDE_CONFIG_DIR). Which account the payload's rate_limits belong
# to is decided by the sidecar attribution below, not by that email alone.
_u="$SESSION_DATA"
# The render creates the data root when nothing else has, so it is the one that
# has to set the root's posture: 700 comes from the lib's umask, and the
# .gitignore keeps a store that lands inside a tracked config dir out of a
# commit. The second guard is on the FILE, not the directory — --hook, the
# rewake waiter and the resume queue all create the root without writing one,
# and a directory-keyed guard would then never fire again. `-s` rather than the
# installer's content comparison because this runs every ten seconds and a `cat`
# per render buys nothing: a populated .gitignore someone put there is theirs.
[ -d "$_u" ] || mkdir -p "$_u"
[ -s "$_u/.gitignore" ] || printf '*\n' > "$_u/.gitignore"
_cfg="$SESSION_CFG"
_acct=$(session_login)
_cache=$(session_cache_path)

# Credential autosave (`session account`): copy the live login into the vault
# whenever .credentials.json has moved since the vault entry was written. This
# is what makes a bare `/login` non-destructive — the login being REPLACED was
# already captured while it was live, so it stays switchable back to. Guarded
# on mtime so the common render costs two stats and nothing else; the vault
# write itself rotates the old copy into .history/ rather than overwriting.
_vault="$SESSION_ACCOUNTS_DIR"
if [ "$_acct" != unknown ] && [ -s "$_cfg/.credentials.json" ]; then
  _vf="$_vault/$_acct.json"
  if [ ! -e "$_vf" ] || [ "$_cfg/.credentials.json" -nt "$_vf" ]; then
    "$SESSION_HOME/session" account save >/dev/null 2>&1 || true
  fi
fi
_now=$(now_epoch)
_intonly() { local v="${1%%.*}"; case "$v" in ''|*[!0-9]*) printf 0 ;; *) printf '%s' "$v" ;; esac; }
# "-" sentinel for missing string fields (session_id, model, prompt_id): an
# empty field would be eaten by `read` under IFS=tab (tab is IFS whitespace,
# and consecutive tabs merge), shifting fields; numerics all have // defaults
IFS=$'\t' read -r _sid _cost _f5 _w7 _new_fr _new_wr _dur _apidur \
                 _otok _itok _ctx _crd _ccr _cin _cout _ladd _lrm _model _pid _cwd < <(
  jq -r '[(.session_id//"-"),(.cost.total_cost_usd//0),
          (.rate_limits.five_hour.used_percentage//-1),
          (.rate_limits.seven_day.used_percentage//-1),
          ((.rate_limits.five_hour.resets_at//0)|floor),
          ((.rate_limits.seven_day.resets_at//0)|floor),
          ((.cost.total_duration_ms//0)|floor),
          ((.cost.total_api_duration_ms//0)|floor),
          (.context_window.total_output_tokens//0),
          (.context_window.total_input_tokens//0),
          (.context_window.used_percentage//-1),
          (.context_window.current_usage.cache_read_input_tokens//0),
          (.context_window.current_usage.cache_creation_input_tokens//0),
          (.context_window.current_usage.input_tokens//0),
          (.context_window.current_usage.output_tokens//0),
          (.cost.total_lines_added//0),
          (.cost.total_lines_removed//0),
          (.model.id//"-"),
          (.prompt_id//"-"),
          (.cwd//.workspace.current_dir//"-")]|@tsv' <<<"$input")
_new_fr=$(_intonly "$_new_fr"); _new_wr=$(_intonly "$_new_wr")
# Attribution: the payload's rate_limits belong to whichever account served this
# SESSION's last API response — not necessarily the login now in .claude.json.
# `session account use` (or /login) flips the email instantly, but a session's
# payload keeps replaying the outgoing account's windows until its next request
# completes; keying the write on the email alone let a switch poison the
# incoming login's cache with the outgoing one's data (2026-08-05: wk 91%
# written under a 3% account, and the old resets_at-monotonic guard — built for
# idle sessions replaying elapsed windows — then rejected every genuine write
# for days because the foreign weekly reset later). A per-session sidecar holds
# the last-seen window tuple + the login that owned it: a CHANGED tuple proves
# a response just arrived under the current login (only responses move
# rate_limits, and resets_at collisions across accounts don't happen — 5h
# windows are usage-anchored), so only those renders write the cache. Unchanged
# tuples never write, which retires the old guard: its stale-idle-clobber case
# can no longer occur, and within one account a changed tuple is always the
# newest data there is.
#   The sidecar is keyed per payload STREAM — (sid, pane) — not per session:
# one session id can be live in two processes at once (`claude -r` of a
# still-running session), each replaying a different frozen payload. Under a
# shared sidecar the tuple alternates every render, every alternation passes
# the changed-tuple test, and both stale payloads get stamped with the live
# login (2026-08-26: team shown 5h 19% while really capped at 100%). TMUX_PANE
# is process-stable and distinct across processes (same inheritance as the
# pane map below); outside tmux the key stays the bare sid.
_snapdir="$SESSION_SNAPDIR"
[ -d "$_snapdir" ] || mkdir -p "$_snapdir"
_owner=""; _fresh=0
if [ -n "$_sid" ] && [ "$_sid" != "-" ]; then
  _pane="${TMUX_PANE:-}"; _pane=${_pane//[!0-9A-Za-z]/}
  _lim="$_snapdir/$_sid${_pane:+.p$_pane}.limits"
  _tuple="$_f5 $_w7 $_new_fr $_new_wr"
  if [ -s "$_lim" ]; then
    IFS=$'\t' read -r _p_tuple _p_owner < "$_lim"
    if [ "$_tuple" = "$_p_tuple" ]; then
      _owner="$_p_owner"
    else
      _owner="$_acct"; _fresh=1
      printf '%s\t%s\n' "$_tuple" "$_acct" > "$_lim"
    fi
  else
    # first sighting: the tuple's owner is unknowable (a fresh session's first
    # render can already carry another account's windows) — record it unowned;
    # the session's next response flips it to the live login.
    printf '%s\t%s\n' "$_tuple" "-" > "$_lim"
  fi
fi
_old_f5=-1; _old_w7=-1; _old_fr=0; _old_wr=0
if [ -s "$_cache" ]; then
  IFS=$'\t' read -r _old_f5 _old_w7 _old_fr _old_wr < <(
    jq -r '[(.rate_limits.five_hour.used_percentage//-1),
            (.rate_limits.seven_day.used_percentage//-1),
            ((.rate_limits.five_hour.resets_at//0)|floor),
            ((.rate_limits.seven_day.resets_at//0)|floor)]|@tsv' "$_cache")
  _old_fr=$(_intonly "$_old_fr"); _old_wr=$(_intonly "$_old_wr")
fi
if [ "$_fresh" = 1 ] && { [ "$_new_fr" -gt "$_now" ] || [ "$_new_wr" -gt "$_now" ]; }; then
  # Only what a reader reads back: the two window blocks, the model name, and
  # the Claude Code version `session doctor` reports. The payload also carries
  # cwd, transcript_path, workspace.repo and the prompt id — none of it read by
  # anything, all of it durable on disk once written, so it is dropped here
  # rather than stored against a use nobody has. Written through a temp file in
  # the same directory, so a reader never sees a half-written cache — and named
  # per process, because every render of one login writes this same cache and
  # renders overlap (several sessions on one login answering within a second,
  # each re-rendering every ~10s). Under a shared name the second `>` truncates
  # the first writer's temp, the shorter write lands over the longer one, and
  # the longer one's tail survives past the shorter's end: a complete JSON line
  # followed by a stray `"}`, which is what left a non-live login's cache
  # unparseable for a day (2026-09-14; only a render on that login rewrites it).
  # The lib's prune carries the same rule for the same reason.
  jq -c '{rate_limits, context_window, model, version}' <<<"$input" > "$_cache.tmp.$$" \
    && mv -f "$_cache.tmp.$$" "$_cache"
elif [ "$_owner" = "$_acct" ] && [ -s "$_cache" ] \
     && [ "$_f5" = "$_old_f5" ] && [ "$_w7" = "$_old_w7" ] \
     && [ "$_new_fr" = "$_old_fr" ] && [ "$_new_wr" = "$_old_wr" ]; then
  # same data, same owner: refresh the cache's age (mtime feeds the "Xm old"
  # column and the hook's staleness note) without rewriting content
  touch "$_cache"
fi

# --- Per-session usage sampling (read by `session usage`) ---
# cost.total_cost_usd is the session's CUMULATIVE API-equivalent spend, delivered
# on every render (~10s while active). Append a sample to session-log.tsv whenever
# it moved (plus a 10-min idle heartbeat), so per-session in-window burn can be
# counted from deltas. A per-session snapshot keeps name/model readable without
# scanning transcripts; the .cost sidecar is the dedup state (content = last
# logged cost, mtime = last sample time).
# TSV columns (readers must tolerate shorter lines from older schema versions):
#   1 ts  2 sid  3 cost_usd  4 five%  5 week%  6 five_reset  7 week_reset
#   8 duration_ms  9 api_duration_ms          (cumulative; 8 is WALL clock —
#     it ticks through idle, so deltas include gaps; turn time comes from the
#     hook-fed turn-log instead)
#   10 total_output_tokens  11 total_input_tokens        (cumulative)
#   12 context%  13 cache_read  14 cache_creation  15 cur_input  16 cur_output
#     (current-request context composition — gauges, not counters)
#   17 lines_added  18 lines_removed             (cumulative)
#   19 model_id  20 prompt_id                    (strings, "-" if absent;
#     prompt_id joins samples to turn-log turns by time-bracket or id)
#   21 account                                   (login email; readers filter on
#     it so attribution never mixes accounts — windows are per-login)
# Only columns 1-8 are read by the attribution estimator (8 separates two
# processes rendering under one sid, so deltas stay within a process); the rest are logged
# so the history exists when a view wants them (`session time` v1, cache-
# efficiency, context-growth, per-turn cost). Static payload fields (version,
# cwd, workspace, effort, …) are NOT time-series'd, and the per-session snapshot
# below keeps only the session's title — the one field anything reads back.
_slog="$SESSION_SLOG"
if [ -n "$_sid" ] && [ "$_sid" != "-" ] && _costf=$(LC_ALL=C printf '%.4f' "$_cost" 2>/dev/null); then
  _side="$_snapdir/$_sid.cost"
  _prevf=""; _side_age=999999
  if [ -e "$_side" ]; then
    _prevf=$(cat "$_side")
    _side_age=$(( _now - $(mtime_of "$_side") ))
  fi
  # pane → session map for attended-time (focus) tracking: TMUX_PANE is
  # inherited from the pane shell through claude into this hook. touch keeps a
  # live pane's mtime fresh so the daily prune only sweeps dead panes.
  if [ -n "${TMUX_PANE:-}" ]; then
    _pdir="$SESSION_PANEDIR"; [ -d "$_pdir" ] || mkdir -p "$_pdir"
    _pf="$_pdir/${TMUX_PANE#%}"
    if [ -e "$_pf" ] && [ "$(cat "$_pf")" = "$_sid" ]; then touch "$_pf"
    else printf '%s' "$_sid" > "$_pf"; fi
  fi
  if [ "$_costf" != "$_prevf" ] || [ "$_side_age" -ge 600 ]; then
    LC_ALL=C printf '%s\t%s\t%s\t%.3f\t%.3f\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$_now" "$_sid" "$_costf" "$_f5" "$_w7" "$_new_fr" "$_new_wr" "$_dur" "$_apidur" \
      "$_otok" "$_itok" "$_ctx" "$_crd" "$_ccr" "$_cin" "$_cout" "$_ladd" "$_lrm" "$_model" "$_pid" "$_acct" >> "$_slog"
    printf '%s' "$_costf" > "$_side"
    jq -c '{session_name}' <<<"$input" > "$_snapdir/.$_sid.tmp.$$" \
      && mv -f "$_snapdir/.$_sid.tmp.$$" "$_snapdir/$_sid.json"
  fi
fi
# Daily prune. The rule, the marker and the archive live in the lib, because
# `session --session-end` prunes through the same function: neither producer has
# to be installed for the logs to stay bounded. Costs two stats on the
# once-a-day check, which is what every render but one pays.
session_prune_daily

# --- Rate-limit segments -----------------------------------------------------
# rate_limits only refresh on an API RESPONSE, so a session that is idle — or
# rate-limited, which is exactly when you check — keeps rendering the last window
# it was told about. Once that resets_at passes, the countdown used to clamp to
# "0h0m left", which reads as "the cap is up" when it is not. Corrections:
#   • the payload is trusted as-is only when it is provably fresh (_fresh). A
#     same-account payload (_owner matches) competes per window with the shared
#     cache — whichever resets_at is later wins, valid within one account; pct
#     and reset are carried as a PAIR so they stay coherent. A payload owned by
#     another login or by nobody yet (pre-switch replay, first render) is
#     foreign: show the account's own cache instead of someone else's windows.
#   • never print a bare zero for an expired window. The weekly can be recovered —
#     fixed 7-day cadence off a wall-clock anchor (2026-07-19, -26 and 08-02 all
#     15:00 UTC, exactly 604800 s between them) — so step it forward and mark it ~. The 5h
#     window CANNOT: it is usage-anchored, opening on the first request after an
#     idle gap, so its phase moves (observed boundaries at :00/:10/:20/:40/:50 and
#     inter-window gaps of 5.00h through 27h). Stepping a stale 07-26 14:00 forward
#     gives 10:00 where the live value was 09:10 — so it is flagged, not guessed.
_d_f5=$_f5; _d_fr=$_new_fr; _d_w7=$_w7; _d_wr=$_new_wr
if [ "$_fresh" != 1 ]; then
  if [ "$_owner" = "$_acct" ]; then
    if [ "$_old_fr" -gt "$_d_fr" ]; then _d_f5=$_old_f5; _d_fr=$_old_fr; fi
    if [ "$_old_wr" -gt "$_d_wr" ]; then _d_w7=$_old_w7; _d_wr=$_old_wr; fi
  elif [ "$_old_fr" -gt 0 ] || [ "$_old_wr" -gt 0 ]; then
    _d_f5=$_old_f5; _d_fr=$_old_fr; _d_w7=$_old_w7; _d_wr=$_old_wr
  fi
fi
_hm() { local s=$1; [ "$s" -lt 0 ] && s=0; printf '%dh%dm' $(( s/3600 )) $(( (s%3600)/60 )); }
# Rounded, and h+m below a day. Flooring the hour drops up to 59m, which is what
# turned 58 minutes of weekly headroom into a flat "0d0h".
_dh() { local s=$1 h; [ "$s" -lt 0 ] && s=0
        if [ "$s" -lt 86400 ]; then _hm "$s"; return; fi
        h=$(( (s + 1800) / 3600 )); printf '%dd%dh' $(( h/24 )) $(( h%24 )); }
_seg() {  # $1=label  $2=pct  $3=resets_at  $4=cadence secs (0 = not projectable)
  local p="${2%%.*}" r="$3" w="$4" left
  if [ -z "$p" ] || [ "$p" = "-1" ]; then return; fi
  if [ "$r" -le 0 ]; then printf ', %s: %s%%' "$1" "$p"; return; fi
  if [ "$r" -gt "$_now" ]; then
    left=$(( r - _now ))
    if [ "$w" -gt 0 ]; then printf ', %s: %s%% (%s left)' "$1" "$p" "$(_dh "$left")"
    else                    printf ', %s: %s%% (%s left)' "$1" "$p" "$(_hm "$left")"; fi
  elif [ "$w" -gt 0 ]; then
    left=$(( r + w * ( (_now - r + w - 1) / w ) - _now ))
    printf ', %s: %s%%? (~%s left)' "$1" "$p" "$(_dh "$left")"
  else
    printf ', %s: %s%%? (stale)' "$1" "$p"
  fi
}
_five_seg=$(_seg 5h "$_d_f5" "$_d_fr" 0)
_week_seg=$(_seg wk "$_d_w7" "$_d_wr" 604800)
# Tag the line with the account-dir name when running under a non-primary
# login, so mixed-account windows are distinguishable at a glance.
_atag=""
session_nondefault_cfg && _atag=" · ${_cfg##*/}"

# --- Task segment ------------------------------------------------------------
# The tasksync task this session is on, its title anchored as an OSC 8
# hyperlink to the Notion row. Claude Code's status line renders OSC 8 (its
# ANSI carry-over regex names the sequence); under tmux the outer terminal must
# carry the `hyperlinks` terminal-feature or tmux strips it, and a terminal with
# no support shows the bare title. Two signals, in order:
#   • the task folder containing the session's working directory — the rule
#     `tasks ls` and `tasks pull` stamp identity.json's last_session by, and the
#     one fact about the session that no later verb changes;
#   • `tasks/.sync/session-task.json`, keyed by session id: the task the
#     session last created, promoted, drafted, beat on or adopted (tasksync's
#     `mark_session_task`). --fyi beats stamp it like any other, so a drive-by
#     note on another task shows that task until the next beat here. A slug
#     whose folder is gone is skipped, not shown.
# The workspace is the nearest ancestor of the cwd carrying `tasks/.sync` (the
# beat reminder's rule): a session inside the checkout that is on a task shows
# which; one outside every workspace, or that never touched a task, shows
# nothing. The title is the row's
# (identity.json; a draft has none, so its task.md H1), cut to its headline
# before ": ", " — " or " - " when that headline is a phrase of its own (12+
# characters), then clipped to 40 at a word boundary with an ellipsis.
# Shortening runs in jq, which slices by code point: bash under a C locale would
# cut a multibyte character in half. A draft has no row, so it is unlinked.
_task_seg=""
_wsroot=""
case "$_cwd" in
  /*) _d="$_cwd"
      while [ -n "$_d" ]; do
        if [ -d "$_d/tasks/.sync" ]; then _wsroot="$_d"; break; fi
        _d="${_d%/*}"
      done ;;
esac
_slug=""
if [ -n "$_wsroot" ]; then
  case "$_cwd" in
    "$_wsroot"/tasks/*) _slug=${_cwd#"$_wsroot"/tasks/}; _slug=${_slug%%/*} ;;
  esac
  _mk="$_wsroot/tasks/.sync/session-task.json"
  if [ -z "$_slug" ] && [ "$_sid" != "-" ] && [ -s "$_mk" ]; then
    _slug=$(jq -r --arg s "$_sid" '.[$s].slug // empty' "$_mk")
  fi
  # A slug is one folder name under tasks/: a pointer carrying a path (tasksync
  # never writes one, but the file is plain JSON on disk) must not resolve a
  # folder outside the tree, and a vanished folder is not a task.
  case "$_slug" in */*|.*) _slug="" ;; esac
  [ -n "$_slug" ] && [ ! -d "$_wsroot/tasks/$_slug" ] && _slug=""
fi
if [ -n "$_slug" ]; then
  _short='def short($n):
    (if test(": | — | - ") then split(": | — | - "; "")[0] else . end) as $h
    | (if ($h | length) >= 12 then $h else . end)
    | if length <= $n then .
      else . as $s | $s[:$n]
        | (if ($s[$n:$n+1] | test("\\s")) then . else sub("\\s+\\S*$"; "") end)
        | sub("[\\s,;:—–(\"\u201c\u2018-]+$"; "") + "…"
      end;'
  _tdir="$_wsroot/tasks/$_slug"
  _ttl=""; _url=""
  if [ -s "$_tdir/identity.json" ]; then
    # Two lines, url first. A title is read through the same flattening tasksync
    # applies on the way in (model.normalize_title), so a stray newline can
    # neither retarget the link nor spill a third line.
    { read -r _url; read -r _ttl; } < <(jq -r "$_short"'(.url // ""), (.title // "" | gsub("[\\r\\n\\t]+"; " ") | short(40))' "$_tdir/identity.json")
  elif [ -s "$_tdir/task.md" ]; then
    _h1=$(awk '/^# /{sub(/^# /, ""); print; exit}' "$_tdir/task.md")
    [ -n "$_h1" ] && _ttl=$(jq -rn --arg t "$_h1" "$_short"'$t | short(40)')
  fi
  if [ -n "$_ttl" ] && [ -n "$_url" ]; then
    # BEL-terminated, the form Claude Code's own link helpers emit
    _task_seg=$(printf ' · \033]8;;%s\a%s ↗\033]8;;\a' "$_url" "$_ttl")
  elif [ -n "$_ttl" ]; then
    _task_seg=" · $_ttl"
  fi
fi

jq -r --arg five_seg "$_five_seg" --arg week_seg "$_week_seg" --arg atag "$_atag" \
      --arg task_seg "$_task_seg" '
  # model + effort come fresh in every render payload, so this tracks
  # mid-session switches (Fable safeguard fallback to Opus, /model, /effort)
  # without any caching
  (.model.display_name // .model.id // "") as $mn |
  (.effort.level // "") as $ef |
  (if $mn == "" and $ef == "" then ""
   elif $ef == "" then $mn + " · "
   elif $mn == "" then $ef + " · "
   else "\($mn) (\($ef)) · " end) as $model |
  (.context_window.current_usage // {}) as $cu |
  ([$cu.input_tokens, $cu.cache_creation_input_tokens, $cu.cache_read_input_tokens]
    | map(. // 0) | add) as $used |
  def fmt:
    if . >= 1000000 then
      (. / 100000 | floor) as $d |
      "\($d / 10 | floor).\($d % 10)M"
    elif . >= 1000 then
      "\(. / 1000 | floor)k"
    else "\(.)" end;
  "\($model)\($used | fmt) tkns\($five_seg)\($week_seg)\($task_seg)\($atag)"
' <<< "$input"
