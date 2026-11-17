# shellcheck shell=bash
# Compacting a session after it is closed, while its prompt cache is warm.
#
# A session that holds a large context and is closed before Claude Code's own
# idle compaction reaches it costs the whole context in cache writes when it is
# reopened after the cache has expired. So about 50 minutes after its last
# request, inside the 1-hour prompt-cache lifetime, a headless `claude -p
# --resume` run compacts it: that run reads the cache the session left, where a
# compaction after the expiry would read the context uncached. The thresholds
# assume that lifetime, as the plugin's do (hooks/compact-before-switch.ts).
#
# Three entry points of `session` use this file:
#   --session-end          the hook, inside its two seconds: a cheap gate, then
#                          cc_session_end detaches a waiter and returns
#   --close-compact-wait   the waiter (cc_wait): reads the transcript, names
#                          itself in the session's state file, sleeps until the
#                          compaction is due, then starts a fresh process for
#   --close-compact        the decision (cc_decide), so the switch and the code
#                          are the ones in force when it is due
#
# SOURCED, NEVER EXECUTED. Like the libs it follows it sets no shell options and
# reads no stdin. It needs lib/common.sh and lib/compact.sh sourced first, and jq.
#
# Observed by hand on Claude Code 2.1.326 (CLAUDE.md says how to look again):
# the hook runs in a process group and a session of its own and is killed with
# its descendants at the entry's timeout, so only a process that is out of its
# group and no longer its descendant outlives a slow hook; the hook's payload
# names the shell's current folder, not the one the session was launched in; a
# headless run registers in the presence registry under its own pid, with the
# session's id; and `claude -p --resume ID /compact`, run from the launch folder
# on the model of the last request, reads the cache the session left.

CC_POLL=1   # seconds between looks at a running compaction

# Run a command detached: a fresh session (so it is out of the hook's process
# group) that is not a descendant either, since Claude Code kills the hook's
# descendants as well as its group when the entry times out. perl does the
# fork and setsid on every platform; setsid(1) is not on macOS.
cc_detach() {  # COMMAND ARGS...
  perl -e 'use POSIX; defined(my $p = fork) or exit 1; exit if $p; POSIX::setsid(); exec { $ARGV[0] } @ARGV' \
    "$@" >/dev/null 2>&1 </dev/null
}

# What the hook does: start a waiter for a session that was closed by exit or by
# its window or process going away, when it is an interactive one. The headless
# run that compaction itself starts is a session too, and ends with reason
# `other`; its entrypoint (`sdk-cli`) is what separates them, and the
# guard in `session` stops anything it triggers before it gets here.
cc_session_end() {  # SID REASON TRANSCRIPT CWD
  [ "${SESSION_CLOSE_COMPACT:-on}" = on ] || return 0
  case "$2" in prompt_input_exit|other) ;; *) return 0 ;; esac
  [ "${CLAUDE_CODE_ENTRYPOINT:-}" = cli ] || return 0
  case "$1" in ''|*[!0-9A-Za-z-]*) return 0 ;; esac
  [ -d "$SESSION_DATA" ] || return 0
  cc_detach bash "$SESSION_HOME/session" --close-compact-wait "$1" "$3" "$4" "$(session_login_read)"
}

cc_log() {  # SID EVENT REASON [DETAIL] — one row; tab and newline in a detail become spaces
  local d=${4:-}
  d=$(printf '%s' "$d" | tr '\t\n' '  ' | cut -c1-400)
  printf '%s\t%s\t%s\t%s\t%s\n' "$(now_epoch)" "$1" "$2" "${3:--}" "${d:--}" >> "$SESSION_CCLOG"
}

cc_get() {  # STATEFILE KEY
  sed -n "s/^$2=//p" "$1"
}

# The folder the session was launched in, which the run has to start from: the
# environment it resumes with, and with it the cache, are those of a launch
# folder, and the hook's own cwd follows every `cd` the shell made. The
# transcripts are filed under that folder's name, every character that is not
# a letter or digit turned into a dash. The hook's folder is taken when it
# has that name, else the first folder the transcript itself records that has.
cc_dir() {  # TRANSCRIPT CWD
  local slug c
  slug=$(basename "$(dirname "$1")")
  { printf '%s\n' "$2"
    head -c 1000000 "$1" | grep -ao '"cwd":"[^"]*"' | sed -e 's/^"cwd":"//' -e 's/"$//'
  } | while IFS= read -r c; do
    [ "${c//[!A-Za-z0-9]/-}" = "$slug" ] && { printf '%s\n' "$c"; break; }
  done
}

# The pid of a live process other than EXCLUDE that holds the session, from
# Claude Code's presence registry. A headless resume registers there too, under
# its own pid and the session's id.
cc_open_pid() {  # SID EXCLUDE_PID
  local f p
  for f in "$SESSION_CFG"/sessions/*.json; do
    [ -e "$f" ] || break
    grep -Eq "\"sessionId\" *: *\"$1\"" "$f" || continue
    p=$(jq -r '.pid // empty' "$f") || continue
    case "$p" in ''|*[!0-9]*|"$2") continue ;; esac
    kill -0 "$p" 2>/dev/null && { printf '%s\n' "$p"; return 0; }
  done
  return 0
}

# What a transcript says about the session's spending and its last compaction,
# for the run to be measured against: the cost so far, and the newest boundary
# row's uuid, tokens before and tokens after.
cc_cost_state() {  # TRANSCRIPT
  tail -c 4000000 "$1" | jq -Rsr '
    split("\n") | map(select(. != "") | (try fromjson catch null) | select(type == "object" and .type == "cost-state"))
    | last | .totalCostUSD // empty'
}
cc_boundary() {  # TRANSCRIPT -> "UUID PRE POST"
  tail -c 4000000 "$1" | jq -Rsr '
    split("\n") | map(select(. != "") | (try fromjson catch null)
                      | select(type == "object" and .type == "system" and .subtype == "compact_boundary"))
    | last | select(. != null)
    | "\(.uuid // "-") \(.compactMetadata.preTokens // "-") \(.compactMetadata.postTokens // "-")"'
}

# The last lines of a file as one line.
cc_tail() {  # FILE
  tail -n 5 "$1" | tr '\t' ' ' | awk 'NR > 1 { printf " | " } { printf "%s", $0 }'
}

# The waiter. A close names itself in the session's state file before anything
# else, so an older waiter of the same session that wakes finds another name, or
# none, and leaves. Sessions that never qualify leave no row: that is every
# session closed under the floor, and there are many.
cc_wait() {  # SID TRANSCRIPT CWD LOGIN — the login the box was on at the close
  local sid=$1 tp=$2 state token now last tokens model compacted dir wake
  [ -d "$SESSION_DATA" ] || return 0
  now=$(now_epoch)
  token="$now.$$"
  mkdir -p "$SESSION_SNAPDIR"
  state="$SESSION_SNAPDIR/$sid.closecompact"
  rm -f "$state"
  read -r last tokens model compacted <<<"$(compact_last_request "$tp")"
  [ -n "${last:-}" ] && [ "$tokens" -ge "$SESSION_CLOSE_COMPACT_FLOOR" ] || return 0
  if [ "$compacted" != 0 ]; then
    cc_log "$sid" skipped "last event was a compaction"
    return 0
  fi
  dir=$(cc_dir "$tp" "$3")
  if [ -z "$dir" ]; then
    cc_log "$sid" skipped "launch folder unknown"
    return 0
  fi
  printf 'token=%s\nlogin=%s\nlast=%s\nmodel=%s\ncwd=%s\ntranscript=%s\n' \
    "$token" "$4" "$last" "$model" "$dir" "$tp" > "$state.$$" \
    && mv -f "$state.$$" "$state"
  # The cache is warm for an hour from the last request, not from the close: a
  # session idle for 40 minutes and then closed is due in 10, and one closed
  # after 57 is past the latest start and is turned away when it is decided.
  wake=$(( last + SESSION_CLOSE_COMPACT_DELAY ))
  [ "$wake" -le "$now" ] || sleep $(( wake - now ))
  exec bash "$SESSION_HOME/session" --close-compact "$sid" "$token"
}

# Why the compaction must not start now, or nothing. Reads the decision's
# variables.
cc_refusal() {
  local l c p
  [ "${SESSION_CLOSE_COMPACT:-on}" = on ] || { echo "switched off"; return; }
  [ -r "$tp" ] || { echo "transcript gone"; return; }
  read -r l _ _ c <<<"$(compact_last_request "$tp")"
  [ "${l:-}" = "$last0" ] || { echo "further work since the close"; return; }
  [ "$c" = 0 ] || { echo "last event was a compaction"; return; }
  p=$(cc_open_pid "$sid" "")
  [ -z "$p" ] || { echo "open again in process $p"; return; }
  [ "$(session_login_read)" = "$login0" ] || { echo "login changed"; return; }
  [ $(( $(now_epoch) - last0 )) -le "$SESSION_CLOSE_COMPACT_LATEST" ] \
    || { echo "cache cold: last request $(( $(now_epoch) - last0 ))s ago"; return; }
  [ -d "$dir" ] || { echo "folder gone: $dir"; return; }
  command -v claude >/dev/null 2>&1 || echo "claude not on PATH"
}

# The run: a child watched until it ends, stopped when the session is open
# again anywhere but in the run itself, or when it has taken too long. It is
# started in the launch folder with the identity of the session that called
# this left out of its environment, and the guard variable that tells every
# hook of `session` to leave the logs alone.
cc_run() {
  local out err pid start stop="" rc holder prior bd0 bd cost secs detail pre post
  out=$(mktemp "$SESSION_SNAPDIR/.close-compact.XXXXXX")
  err=$(mktemp "$SESSION_SNAPDIR/.close-compact.XXXXXX")
  prior=$(cc_cost_state "$tp")
  bd0=$(cc_boundary "$tp")
  start=$(date +%s)
  ( cd "$dir" && exec env -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT \
      -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_PID -u CLAUDE_CODE_MESSAGING_SOCKET \
      -u CLAUDE_CODE_SESSION_ATTENDED -u TMUX -u TMUX_PANE SESSION_CLOSE_COMPACT_RUN=1 \
      claude -p --resume "$sid" --model "$model" --output-format json /compact </dev/null >"$out" 2>"$err" ) &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    holder=$(cc_open_pid "$sid" "$pid")
    if [ -n "$holder" ]; then stop="open again in process $holder"; break; fi
    if [ $(( $(date +%s) - start )) -ge "$SESSION_CLOSE_COMPACT_LIMIT" ]; then
      stop="over the ${SESSION_CLOSE_COMPACT_LIMIT}s limit"; break
    fi
    sleep "$CC_POLL"
  done
  [ -z "$stop" ] || kill "$pid"
  rc=0; wait "$pid" || rc=$?
  secs=$(( $(date +%s) - start ))
  if [ -n "$stop" ]; then
    cc_log "$sid" stopped "$stop" "secs=$secs"
  elif [ "$rc" -ne 0 ]; then
    # An error can come back as the result on stdout with nothing on stderr.
    detail=$(cc_tail "$err")
    [ -n "$detail" ] || detail=$(jq -r '.result // empty' "$out" | cut -c1-200)
    cc_log "$sid" failed "exit $rc" "$detail"
  else
    bd=$(cc_boundary "$tp")
    if [ -z "$bd" ] || [ "${bd%% *}" = "${bd0%% *}" ]; then
      cc_log "$sid" failed "no compaction recorded" "$(jq -r '.result // empty' "$out" | cut -c1-200)"
    else
      # The run's total is the session's whole cost, the part it had spent
      # before restored from the transcript; the run's own is the difference.
      cost=$(jq -r --arg p "$prior" 'if ($p | test("^[0-9.]+$")) and (.total_cost_usd | type) == "number"
                                     then " cost=\(((.total_cost_usd - ($p | tonumber)) * 10000 | round) / 10000)" else empty end' "$out")
      read -r _ pre post <<<"$bd"
      cc_log "$sid" compacted - "tokens=$pre->$post secs=$secs$cost"
    fi
  fi
  rm -f "$out" "$err"
}

# The decision, in a process started when the compaction is due.
cc_decide() {  # SID TOKEN
  local sid=$1 state login0 last0 model dir tp why
  state="$SESSION_SNAPDIR/$sid.closecompact"
  [ -r "$state" ] && [ "$(cc_get "$state" token)" = "$2" ] || return 0
  login0=$(cc_get "$state" login); last0=$(cc_get "$state" last); model=$(cc_get "$state" model)
  dir=$(cc_get "$state" cwd); tp=$(cc_get "$state" transcript)
  why=$(cc_refusal)
  if [ -n "$why" ]; then
    cc_log "$sid" skipped "$why"
  else
    cc_run
  fi
  [ "$(cc_get "$state" token)" = "$2" ] && rm -f "$state"
  return 0
}
