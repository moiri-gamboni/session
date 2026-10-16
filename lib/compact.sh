# shellcheck shell=bash
# What the compaction hold needs to know about a session's context.
#
# SOURCED, NEVER EXECUTED, and only by the three that need it: the statusline
# (which publishes the ceiling), the PostToolBatch stop and the PreCompact gate.
# Like the lib it follows, it sets no shell options and reads no stdin. It
# needs lib/common.sh sourced first, and jq.

# The context size at which Claude Code starts an automatic compaction: the
# effective auto-compact window less the 20,000 it keeps for the summary and a
# 13,000 buffer. Prints nothing when automatic compaction is off or the answer
# cannot be read. The window is what applies first of: the environment variable,
# then the first of the project's local settings, the project's settings and the
# user's that names one (a model's own entry beating the top-level key in the
# same file), capped at the model's window. Not read: the --autocompact launch
# flag and CLAUDE_AUTOCOMPACT_PCT_OVERRIDE, which a hook cannot see, and managed
# settings.
compact_ceiling() {  # MODEL WINDOW PROJECT_DIR
  local model=$1 win=$2 dir=$3 f v setting="" acw files=()
  case "$win" in ''|*[!0-9]*|0) return 0 ;; esac
  for v in "${DISABLE_AUTO_COMPACT:-}" "${DISABLE_COMPACT:-}"; do
    case "$v" in 1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) return 0 ;; esac
  done
  # A model is entered under its canonical name; the payload says [1m] or a date.
  model=${model%%\[*}
  model=${model%-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]}
  for f in "$dir/.claude/settings.local.json" "$dir/.claude/settings.json" "$SESSION_CFG/settings.json"; do
    [ -r "$f" ] && files[${#files[@]}]=$f
  done
  # The on/off switch and the window resolve separately: the variable replaces
  # the window only.
  if [ ${#files[@]} -gt 0 ]; then
    setting=$(jq -rs --arg m "$model" '
      map(select(type == "object"))
      | (map(.autoCompactEnabled) | map(select(. != null)) | if length > 0 then .[0] else true end) as $on
      | if $on == false then "off"
        else (map(.modelSettings[$m].autoCompactWindow // .autoCompactWindow)
              | map(select(. != null)) | first // "auto") | tostring end' "${files[@]}") || return 0
  fi
  [ "$setting" = off ] && return 0
  # As parseInt reads it: "500k" is 500, which is then raised to the minimum.
  acw=${CLAUDE_CODE_AUTO_COMPACT_WINDOW:-}; acw=${acw%%[!0-9]*}
  [ -n "$acw" ] || acw=$setting
  case "$acw" in ''|*[!0-9]*) acw=$win ;; esac
  [ "$acw" -lt 100000 ] && acw=100000
  [ "$acw" -gt "$win" ] && acw=$win
  echo $(( acw - 33000 ))
}

# Whether a tmux client viewing this session's pane typed within the bridge
# (SESSION_ATTEND_GRACE), the silence that still counts as one working stretch.
# The tail would ask whether the person is still credited after the last key,
# which is a seconds-wide window on a box that sets it short: an autonomous turn
# reaches the ceiling long after the prompt was typed. A hold kept for someone
# who has gone costs nothing but a turn that stops early. Read from tmux now
# rather than from the focus log, whose activity marks land up to a minute late.
compact_attended() {
  [ -n "${TMUX_PANE:-}" ] && command -v tmux >/dev/null 2>&1 || return 1
  tmux list-clients -F $'#{pane_id}\t#{client_activity}' \
    | awk -F'\t' -v p="$TMUX_PANE" -v now="$(now_epoch)" -v bridge="$SESSION_ATTEND_GRACE" \
          '$1 == p && now - $2 <= bridge { found = 1 } END { exit !found }'
}

# What the last request carried, from the end of a transcript: "TOKENS BYTES"
# (input, cache and output tokens of the last request; the bytes of the user and
# attachment rows after it). Prints nothing when the last 1 MB holds no request. Rows may be partial at the cut, hence the catch; the
# synthetic refusal row carries zero usage and must not reset the count. Only
# user rows and attachments become messages: the transcript also stores a copy
# of the system prompt and tools (a prompt_snapshot attachment, up to 111 KB)
# that the request carries from its cache.
compact_context() {  # TRANSCRIPT
  [ -r "$1" ] || return 0
  tail -c 1000000 "$1" | jq -Rsr '
    split("\n") | map(select(. != ""))
    | reduce .[] as $l ({u: null, b: 0};
        ($l | try fromjson catch null) as $r
        | if ($r | type) == "object" and $r.type == "assistant"
             and ($r.isApiErrorMessage | not) and ($r.isSidechain | not)
             and ($r.message.usage.input_tokens != null)
          then .u = ($r.message.usage | (.input_tokens // 0) + (.cache_read_input_tokens // 0)
                       + (.cache_creation_input_tokens // 0) + (.output_tokens // 0))
               | .b = 0
          elif ($r | type) == "object"
               and ($r.type == "user"
                    or ($r.type == "attachment" and $r.attachment.type != "prompt_snapshot"))
          then .b += ($l | utf8bytelength)
          else . end)
    | select(.u != null and .u > 0) | "\(.u) \(.b)"'
}
