#!/usr/bin/env bash
# install.sh — wire this clone into a Claude Code configuration.
#
# What it writes into $CLAUDE_CONFIG_DIR/settings.json, all as absolute paths
# into this clone: the eight lifecycle hook entries, the two auto-resume (rewake)
# entries and the statusLine. Beside that it creates the usage data root, links
# the CLI onto PATH, and writes session.conf — written before the settings
# merge, so no producer this run wires can ever resolve the default data root on
# a machine whose data lives elsewhere.
#
# Run it from a git clone, never from a plugin cache directory: those paths are
# SHA-pinned and ephemeral, and settings.json does not expand
# ${CLAUDE_PLUGIN_ROOT}.
#
# Steps report `ok`, `skip` or `REFUSE`. Past the two entry checks (a plugin
# cache path, a directory you do not own), which stop the run because nothing
# after them would be safe, a refusal never stops a later step — a taken symlink
# name must not cost you the hook entries. Exit status is 1 if any step refused,
# 0 otherwise; the `session doctor` run at the end is information and its status
# is deliberately not part of ours.
set -uo pipefail

# Captured before a flag or session.conf can set it: this is the difference
# between "the environment already names a data root" (worth recording in the
# conf) and "the lib filled in its default" (not worth recording).
env_data_dir="${SESSION_DATA_DIR:-}"

# The build the asyncRewake wake behaviour was verified against. `timeout` is
# not enforced on an async entry at all, so the pair's value is inert there
# and anything that can block is bounded inside the script instead. The
# version matters for the other reason: below it an async hook is not
# backgrounded, so the waiter would run synchronously on every over-threshold
# prompt and sleep there until its window reset. Refused rather than armed
# blind.
REWAKE_MIN_VERSION=2.1.233
# Undocumented-but-observed fields; re-verify after a Claude Code upgrade.
REWAKE_MESSAGE="Claude usage limits (auto-resume waiter):"
REWAKE_SUMMARY="usage waiter: fresh window — auto-resuming"

usage() {
    cat <<'USAGEEOF'
usage: install.sh [options]

  --bindir DIR         where to link the CLI (default: ~/.local/bin)
  --name NAME          the name to link it as (default: session)
  --force-link         take that name over even when something else holds it
  --dry-run            change nothing at all; print the settings.json diff
  --no-rewake          do not arm the auto-resume waiter entries
  --data-dir DIR       usage data root (default: <config dir>/session-usage)
  --main-guard PATH    a script `session resume` runs before it opens windows
  --attend-grace SECS  silence still counted as one working stretch, in seconds
                       (the bridge; default 600)
  --attend-tail SECS   seconds credited after the last interaction of a stretch
                       (default: the bridge)
  --primary-cfg PATH   the config dir this machine treats as its primary login

The last five are recorded in <config dir>/session.conf, because hooks, cron and
tmux inherit no shell environment and an export in a shell profile reaches none
of them. A re-run keeps the recorded values it does not itself carry. Paths are
made absolute: those same callers run from a directory you do not choose.
USAGEEOF
}

bindir=""
name="session"
force_link=0
dry_run=0
no_rewake=0
data_dir=""
main_guard=""
attend_grace=""
attend_tail=""
primary_cfg=""

NL='
'
# A path is absolutised against this run's cwd. hooks, cron and tmux run-shell
# resolve a relative path against THEIR cwd, so a relative value here would send
# each producer to a different directory and lose rows with no error anywhere.
_abs() {
    case "$1" in
        /*)   printf '%s' "$1" ;;
        '~'/*) printf '%s%s' "$HOME" "${1#\~}" ;;
        ./*)  printf '%s/%s' "$PWD" "${1#./}" ;;
        *)    printf '%s/%s' "$PWD" "$1" ;;
    esac
}
# The four conf-bound values are re-expanded by the shell in every hook, cron
# tick, tmux run-shell and statusline render, so a `$`, a quote or a backtick is
# either executed there or breaks the file for every line that follows it.
_check_conf_value() {  # FLAG VALUE
    case "$2" in
        *'"'*|*'$'*|*'`'*|*"$NL"*)
            echo "install.sh: $1 may not contain a quote, a dollar sign, a backtick or a newline: $2" >&2
            echo "            session.conf is sourced by every producer, so those characters would be executed there or break the file." >&2
            exit 2 ;;
    esac
}

while [ $# -gt 0 ]; do
    case "$1" in
        --bindir|--name|--data-dir|--main-guard|--attend-grace|--attend-tail|--primary-cfg)
            [ $# -ge 2 ] || { echo "install.sh: $1 needs a value" >&2; exit 2; }
            case "$1" in
                --bindir)       bindir=$(_abs "$2") ;;
                --name)         name="$2" ;;
                --data-dir)     _check_conf_value "$1" "$2"; data_dir=$(_abs "$2") ;;
                --main-guard)   _check_conf_value "$1" "$2"; main_guard=$(_abs "$2") ;;
                --primary-cfg)  _check_conf_value "$1" "$2"; primary_cfg=$(_abs "$2") ;;
                --attend-grace)
                    case "$2" in
                        ''|*[!0-9]*) echo "install.sh: --attend-grace takes seconds as digits: $2" >&2; exit 2 ;;
                    esac
                    attend_grace="$2" ;;
                --attend-tail)
                    case "$2" in
                        ''|*[!0-9]*) echo "install.sh: --attend-tail takes seconds as digits: $2" >&2; exit 2 ;;
                    esac
                    attend_tail="$2" ;;
            esac
            shift 2 ;;
        --force-link) force_link=1; shift ;;
        --dry-run)    dry_run=1; shift ;;
        --no-rewake)  no_rewake=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *) echo "install.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# The lib fixes every path at source time, so the flags have to reach the
# environment first — otherwise step 3 would create a stray data root beside the
# one this machine actually uses.
[ -n "$data_dir" ]     && export SESSION_DATA_DIR="$data_dir"
[ -n "$main_guard" ]   && export SESSION_TMUX_MAIN_GUARD="$main_guard"
[ -n "$attend_grace" ] && export SESSION_ATTEND_GRACE="$attend_grace"
[ -n "$attend_tail" ]  && export SESSION_ATTEND_TAIL="$attend_tail"
[ -n "$primary_cfg" ]  && export SESSION_PRIMARY_CFG="$primary_cfg"

# This script is always run from the clone by path — it refuses a plugin cache
# and a directory the invoking uid does not own — so it needs no symlink walk,
# only a loud refusal if someone links it anyway and its idea of SESSION_HOME
# would be wrong.
if [ -L "${BASH_SOURCE[0]}" ]; then
    echo "install.sh: run me directly from the clone, not through the symlink ${BASH_SOURCE[0]}" >&2
    echo "            everything I write points at the directory I am in, and through a link that is the wrong one." >&2
    exit 1
fi
case "${BASH_SOURCE[0]}" in
    */*) SESSION_HOME=$(cd -P "${BASH_SOURCE[0]%/*}" && pwd -P) ;;
    *)   SESSION_HOME=$(pwd -P) ;;
esac
. "$SESSION_HOME/lib/common.sh" || { echo "install.sh: cannot read $SESSION_HOME/lib/common.sh" >&2; exit 1; }

CLI="$SESSION_HOME/session"
LINE="$SESSION_HOME/statusline.sh"

refused=0
ok()      { printf 'ok      %s\n' "$1"; }
skipstep(){ printf 'skip    %s\n' "$1"; }
plan()    { printf 'dry-run %s\n' "$1"; }
refuse()  { refused=$((refused + 1)); printf 'REFUSE  %s\n        %s\n' "$1" "$2"; }
WRITE_REMEDY="check that $SESSION_CFG is writable, the filesystem is not read-only and the disk is not full"

# ── 1. is this a clone, and is it ours? ──────────────────────────────────────
# A plugin cache path is SHA-pinned and rewritten on every update, and
# settings.json stores it verbatim: the hooks would point at a directory that no
# longer exists after the next `claude plugin update`.
case "$SESSION_HOME" in
    */plugins/cache/*)
        refuse "this copy lives in a plugin cache ($SESSION_HOME), whose path changes on every update" \
               "install from a git clone of this repository"
        exit 1 ;;
esac
if [ ! -O "$SESSION_HOME" ]; then
    refuse "$SESSION_HOME is not owned by uid $(id -u)" \
           "clone the repository somewhere you own, and run this from there"
    exit 1
fi

printf 'session installer\n  clone   %s\n  config  %s\n\n' "$SESSION_HOME" "$SESSION_CFG"

# ── 2. the settings file ─────────────────────────────────────────────────────
# A settings.json symlinked into a dotfiles repository is a common setup, and
# writing through a tmp+rename would replace the LINK with a regular file: the
# dotfiles copy would silently stop describing the machine. Edit the target.
settings_named="$SESSION_CFG/settings.json"
settings="$settings_named"
settings_ok=1
if ! command -v jq >/dev/null 2>&1; then
    settings_ok=0
    refuse "jq is not installed, and every settings.json edit here goes through it" \
           "install jq (apt install jq / brew install jq) and re-run"
else
    if [ -L "$settings_named" ]; then
        settings=$(realpath_of "$settings_named")
        ok "settings.json: $settings_named is a symlink — editing its target, $settings"
    fi
    if [ ! -e "$settings" ]; then
        if [ "$dry_run" = 1 ]; then
            plan "settings.json: would create $settings as {}"
        else
            mkdir -p "$SESSION_CFG" && printf '{}\n' > "$settings" \
                && ok "settings.json: created $settings" \
                || { settings_ok=0; refuse "cannot create $settings" "$WRITE_REMEDY"; }
        fi
    elif [ ! -r "$settings" ]; then
        settings_ok=0
        refuse "$settings exists but cannot be read" \
               "make it readable (chmod u+r) and re-run; it is left untouched"
    elif ! jq . "$settings" >/dev/null 2>&1; then
        settings_ok=0
        refuse "$settings is not valid JSON, so nothing in it can be merged safely" \
               "fix or move the file (it is left untouched) and re-run"
    else
        ok "settings.json: $settings parses"
    fi
fi

# ── 3. the data root ─────────────────────────────────────────────────────────
# The store holds turn timings and session titles; a clone that ends up inside a
# repository must not carry them into a commit, so the .gitignore is part of
# what "the data root is set up" means and is proved, not assumed.
_gitignore_ok() {
    [ "$(cat "$SESSION_DATA/.gitignore" 2>/dev/null)" = '*' ] && return 0
    printf '*\n' > "$SESSION_DATA/.gitignore" 2>/dev/null || return 1
    [ "$(cat "$SESSION_DATA/.gitignore" 2>/dev/null)" = '*' ]
}
if [ "$dry_run" = 1 ]; then
    plan "data root: would create $SESSION_DATA (700) with a .gitignore of *"
elif mkdir -p "$SESSION_DATA" "$SESSION_SNAPDIR" && chmod 700 "$SESSION_DATA" && _gitignore_ok; then
    ok "data root: $SESSION_DATA (700, .gitignore)"
else
    refuse "cannot set up the data root $SESSION_DATA with its .gitignore" \
           "pass --data-dir DIR, or fix the permissions there"
fi

# ── 4. the CLI on PATH ───────────────────────────────────────────────────────
bindir="${bindir:-$SESSION_BINDIR_DEFAULT}"
link="$bindir/$name"
link_do="make"
link_note=""
if [ -e "$link" ] || [ -L "$link" ]; then
    cur=$(realpath_of "$link")
    if [ "$cur" = "$(realpath_of "$CLI")" ]; then
        link_do="skip"
    elif [ "$force_link" = 1 ]; then
        link_note=" (replacing $cur)"
    else
        case "$cur" in
            # Like the hook entries and the statusLine: a link into a clone of
            # this CLI that no longer exists points at nothing, so refusing it
            # would only make every later install fail over a dead name.
            */session/session)
                if [ -e "$cur" ]; then link_do="refuse"
                else link_note=" (replacing a link to $cur, which no longer exists)"; fi ;;
            *) link_do="refuse" ;;
        esac
    fi
fi
case "$link_do" in
    skip)   skipstep "CLI: $link already points here" ;;
    refuse) refuse "$link already exists and points at $cur" \
                   "re-run with --force-link to take the name over, or --name NAME to use another" ;;
    make)
        if [ "$dry_run" = 1 ]; then
            plan "CLI: would link $link -> $CLI$link_note"
        elif mkdir -p "$bindir" && ln -sfn "$CLI" "$link"; then
            ok "CLI: $link -> $CLI$link_note"
            case ":$PATH:" in
                *":$bindir:"*) ;;
                *) printf '        %s is not on PATH; add:  export PATH="%s:$PATH"\n' "$bindir" "$bindir" ;;
            esac
        else
            refuse "cannot link $link" "pass --bindir DIR pointing somewhere writable"
        fi ;;
esac

# ── 5. session.conf, before any settings write ──────────────────────────────
# A recorded line this run does not carry is kept verbatim: a re-run that adds
# one flag must not silently drop the data root the run before it recorded.
# (Why the file exists, and how its ${VAR:-value} lines take precedence, is
# stated where each is acted on: lib/common.sh reads it, usage() offers the
# flags, and the header written into the file itself tells whoever finds it.)
conf="$SESSION_CFG/session.conf"
conf_body=""
conf_checks=""
_conf_value() {  # a value under the home directory is written as the literal $HOME
    case "$1" in
        "$HOME"/*) printf '$HOME%s' "${1#"$HOME"}" ;;
        *)         printf '%s' "$1" ;;
    esac
}
_conf_for() {  # NAME VALUE — from this run's flag when it has one, else what is recorded
    local kept
    if [ -n "$2" ]; then
        conf_body="$conf_body$1=\"\${$1:-$(_conf_value "$2")}\"$NL"
        conf_checks="$conf_checks$1 $2$NL"
    elif [ -r "$conf" ]; then
        kept=$(sed -n "s/^\($1=.*\)\$/\1/p" "$conf" | sed -n '$p')
        [ -n "$kept" ] && conf_body="$conf_body$kept$NL"
    fi
}
_conf_for SESSION_DATA_DIR        "${data_dir:-$env_data_dir}"
_conf_for SESSION_TMUX_MAIN_GUARD "$main_guard"
_conf_for SESSION_ATTEND_GRACE    "$attend_grace"
_conf_for SESSION_ATTEND_TAIL     "$attend_tail"
_conf_for SESSION_PRIMARY_CFG     "$primary_cfg"

# A conf that is written and then not read is the worst outcome available here:
# every producer silently falls back to the default root while the install
# reports success. So the write is proved by reading it back the way the lib
# does — the same readability check, the same trust gate, the same source. That
# catches a pre-existing unreadable file being rewritten, and a conf the lib
# would skip for its ownership or mode, which the chmod below can only repair on
# a file this user owns.
_conf_verify() {
    local out rc
    [ -r "$conf" ] || return 1
    _session_conf_trusted "$conf" || return 1
    out=$( unset SESSION_DATA_DIR SESSION_TMUX_MAIN_GUARD SESSION_ATTEND_GRACE SESSION_ATTEND_TAIL SESSION_PRIMARY_CFG
           # shellcheck disable=SC1090  # the path is the conf this run just wrote
           . "$conf" 2>/dev/null || exit 1
           printf '%s\n' "SESSION_DATA_DIR ${SESSION_DATA_DIR:-}" \
                         "SESSION_TMUX_MAIN_GUARD ${SESSION_TMUX_MAIN_GUARD:-}" \
                         "SESSION_ATTEND_GRACE ${SESSION_ATTEND_GRACE:-}" \
                         "SESSION_ATTEND_TAIL ${SESSION_ATTEND_TAIL:-}" \
                         "SESSION_PRIMARY_CFG ${SESSION_PRIMARY_CFG:-}" )
    rc=$?
    [ "$rc" = 0 ] || return 1
    while IFS= read -r want; do
        [ -n "$want" ] || continue
        case "$out" in *"$want"*) ;; *) return 1 ;; esac
    done <<CHECKEOF
$conf_checks
CHECKEOF
    return 0
}

if [ -z "$conf_body" ]; then
    skipstep "session.conf: nothing to record (no --data-dir/--main-guard/--attend-grace/--attend-tail/--primary-cfg)"
elif [ "$dry_run" = 1 ]; then
    plan "session.conf: would write $conf"
    printf '%s' "$conf_body" | sed 's/^/          /'
else
    mkdir -p "$SESSION_CFG"
    # `>` keeps the mode of a file that already existed, and the lib skips a conf
    # that is group- or world-writable — which is how a run reported `ok` over a
    # conf every producer then ignored, each one falling back to the default
    # root. A conf written where there was none is already 600 from the lib's
    # umask; this makes the pre-existing one 600 too, before _conf_verify proves
    # the lib will read it.
    if { printf '# written by install.sh — read by lib/common.sh before it fills in\n'
         printf '# any default, because hooks, cron and tmux inherit no shell environment.\n'
         printf '%s' "$conf_body"; } > "$conf" && chmod 600 "$conf" && _conf_verify; then
        ok "session.conf: $conf"
    else
        refuse "session.conf at $conf was not written, or does not read back the way lib/common.sh reads it" \
               "$WRITE_REMEDY, that the file is readable (chmod u+r), and that it is yours — the lib skips a conf owned by someone else"
    fi
fi

# ── 6. the settings merge ────────────────────────────────────────────────────
# Compares dot-separated integer tuples: 2.1.99 is older than 2.1.233, which a
# string comparison gets backwards.
_ver_ge() {  # _ver_ge A B -> true when A >= B
    local a="$1" b="$2" x y
    while [ -n "$a" ] || [ -n "$b" ]; do
        x=${a%%.*}; y=${b%%.*}
        case "$a" in *.*) a=${a#*.} ;; *) a="" ;; esac
        case "$b" in *.*) b=${b#*.} ;; *) b="" ;; esac
        x=${x%%[!0-9]*}; y=${y%%[!0-9]*}
        [ -n "$x" ] || x=0
        [ -n "$y" ] || y=0
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 0
}

rewake=false
# A refusal here is "I could not check", not "turn it off": entries that are
# already armed and working stay. Only an explicit --no-rewake disarms.
keep_armed=0
if [ "$no_rewake" = 1 ]; then
    skipstep "auto-resume: not armed (--no-rewake); any existing entries are removed"
elif ! command -v claude >/dev/null 2>&1; then
    keep_armed=1
    refuse "no \`claude\` on PATH, so the harness version behind the auto-resume waiter cannot be checked (needs >= $REWAKE_MIN_VERSION); entries already armed are left as they are" \
           "put claude on PATH and re-run, or re-run with --no-rewake to install everything else"
else
    cv=$(claude --version 2>/dev/null); cv=${cv%% *}
    if [ -n "$cv" ] && _ver_ge "$cv" "$REWAKE_MIN_VERSION"; then
        rewake=true
    else
        keep_armed=1
        refuse "Claude Code ${cv:-(no version)} is older than $REWAKE_MIN_VERSION, where an asyncRewake hook is not backgrounded: the waiter would run synchronously and block every over-threshold prompt until its window reset; entries already armed are left as they are" \
               "upgrade Claude Code and re-run, or re-run with --no-rewake"
    fi
fi

if [ "$settings_ok" = 1 ]; then
    # Everything below reads this string rather than the file, so a --dry-run on
    # a config directory with no settings.json yet still has something to merge
    # into and still writes nothing.
    if [ -e "$settings" ]; then cur_json=$(cat "$settings"); else cur_json='{}'; fi

    spec=$(jq -n --arg s "$CLI" --argjson armed "$rewake" \
                 --arg msg "$REWAKE_MESSAGE" --arg sum "$REWAKE_SUMMARY" '
        def life($e; $m; $mode):
            {event:$e, matcher:$m,
             entry:{type:"command", command:"bash \($s) \($mode) || true", timeout:2}};
        # No `|| true` on the pair: exit 2 IS the wake signal, and swallowing it
        # turns the waiter into a no-op that still sleeps out its whole wait.
        # The timeout below is inert on an async entry — the harness does not
        # enforce it there — and is kept only as a defence should that change.
        # The Auto-resume section of README.md carries the whole of it.
        def wake($e):
            {event:$e, matcher:null,
             entry:{type:"command", command:"bash \($s) --rewake-waiter", timeout:700000,
                    asyncRewake:true, rewakeMessage:$msg, rewakeSummary:$sum}};
        [ life("UserPromptSubmit"; null; "--hook"),
          life("Stop"; null; "--turn-end"),
          life("StopFailure"; null; "--turn-fail"),
          life("SessionEnd"; null; "--session-end"),
          life("SubagentStart"; null; "--subagent-start"),
          life("SubagentStop"; null; "--subagent-end"),
          life("PostCompact"; null; "--compact-mark"),
          life("Notification"; "permission_prompt"; "--perm-mark") ]
        + (if $armed then [wake("UserPromptSubmit"), wake("StopFailure")] else [] end)')

    # The path out of a command of the shape this installer writes:
    # `bash <path> --<mode>[ || true]`, or a host's older `<path> --<mode>`.
    # Read off the shape, never by word-splitting: a clone path containing a
    # space would otherwise yield a fragment that exists nowhere, and the
    # dead-path rule below would delete a live entry belonging to someone else.
    _entry_path() {
        local c="$1"
        case "$c" in "bash "*) c=${c#bash } ;; esac
        case "$c" in *" --"*) c=${c%%" --"*} ;; *) return 1 ;; esac
        case "$c" in /*) printf '%s' "$c"; return 0 ;;
                     '~'/*) printf '%s%s' "$HOME" "${c#\~}"; return 0 ;; esac
        return 1
    }

    # Entries to remove before adding ours: this install's own (so a re-run
    # replaces rather than duplicates) and any entry of this exact shape whose
    # script is gone — a clone that was moved or deleted leaves hooks that fail
    # on every turn. Another clone's live entries and every foreign entry stay.
    drop_body=""
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        p=$(_entry_path "$c") || continue
        if [ "$p" = "$CLI" ]; then
            # Matched on the path rather than on a regex over the command, so a
            # re-run stays idempotent from a clone directory of any name.
            if [ "$keep_armed" = 1 ]; then
                case "$c" in *" --rewake-waiter") continue ;; esac
            fi
            drop_body="$drop_body$c$NL"
            continue
        fi
        [ -e "$p" ] && continue
        # A dead path is dropped only on the shape this CLI is actually written
        # as, a clone's `bash …/session/session --…` (uninstall.sh matches it
        # identically, `~/…` included). Anything else whose script is missing
        # belongs to someone else, broken or not.
        case "$c" in
            "bash "*"/session/session --"*) drop_body="$drop_body$c$NL" ;;
        esac
    done <<DROPEOF
$(printf '%s' "$cur_json" | jq -r '[.hooks[]?[]?.hooks[]? | .command // empty] | .[]')
DROPEOF
    drop=$(printf '%s' "$drop_body" | jq -R -s 'split("\n") | map(select(length > 0))')

    # The statusLine: ours, foreign, or ours-but-pointing-at-a-deleted-clone.
    # A non-object .statusLine is foreign — jq errors on indexing it, and an
    # empty result must not read as "no statusLine is set".
    set_statusline=true
    sl_type=$(printf '%s' "$cur_json" | jq -r '.statusLine | type')
    if [ "$sl_type" != "null" ] && [ "$sl_type" != "object" ]; then
        set_statusline=false
        refuse "settings.json carries a statusLine that is not an object (it is a $sl_type), so it is not ours to replace" \
               "leave it, or merge this object into settings.json by hand:"
        printf '          {"statusLine": {"type": "command", "command": "bash %s", "refreshInterval": 10}}\n' "$LINE"
    elif [ "$sl_type" = "object" ]; then
        cur_sl=$(printf '%s' "$cur_json" | jq -r '.statusLine.command // empty')
        sl_path="$cur_sl"
        case "$sl_path" in "bash "*) sl_path=${sl_path#bash } ;; esac
        case "$sl_path" in '~'/*) sl_path="$HOME${sl_path#\~}" ;; esac
        if [ -n "$cur_sl" ] && [ "$(realpath_of "$sl_path")" != "$(realpath_of "$LINE")" ]; then
            case "$sl_path" in
                # Same treatment the hook entries get: a statusLine of this
                # shape whose file is gone is a moved clone, not a foreign tool,
                # and refusing it forever would make every later install exit 1.
                */session/statusline.sh)
                    if [ -e "$sl_path" ]; then
                        set_statusline=false
                    else
                        ok "statusLine: replacing $cur_sl, which no longer exists"
                    fi ;;
                *) set_statusline=false ;;
            esac
            if [ "$set_statusline" = false ]; then
                refuse "settings.json already carries a statusLine that is not ours: $cur_sl" \
                       "leave it, or merge this object into settings.json by hand:"
                printf '          {"statusLine": {"type": "command", "command": "bash %s", "refreshInterval": 10}}\n' "$LINE"
            fi
        fi
    fi

    merged=$(jq --argjson spec "$spec" --argjson drop "$drop" --argjson setline "$set_statusline" \
                --arg slcmd "bash $LINE" '
        # Only groups that already carry a hooks array are touched: giving a
        # foreign group an empty one would edit a group we have no business in.
        .hooks = ((.hooks // {}) | with_entries(
            .value |= map(if (.hooks | type) == "array"
                          then .hooks |= map(select(. as $e | ($drop | index($e.command // "")) | not))
                          else . end)))
        | reduce $spec[] as $s (.;
            .hooks[$s.event] = (
                (.hooks[$s.event] // []) as $g
                | ([ $g | to_entries[] | select((.value.matcher // null) == ($s.matcher // null)) | .key ] | first) as $i
                | if $i == null
                  then $g + [ (if $s.matcher == null then {} else {matcher: $s.matcher} end) + {hooks: [$s.entry]} ]
                  else $g | .[$i].hooks = (($g[$i].hooks // []) + [$s.entry])
                  end))
        | (if $setline then .statusLine = {type: "command", command: $slcmd, refreshInterval: 10} else . end)' <<<"$cur_json")

    if [ -z "$merged" ]; then
        refuse "the settings merge produced nothing" "re-run with --dry-run and report the output"
    else
        # ── 7. write, or show what would change ──────────────────────────────
        if [ -n "$drop_body" ]; then
            ndrop=$(printf '%s' "$drop_body" | grep -c .)
            printf '        %s %s existing entr%s of this CLI:\n' \
                "$([ "$dry_run" = 1 ] && echo 'would replace' || echo replacing)" \
                "$ndrop" "$([ "$ndrop" = 1 ] && echo y || echo ies)"
            printf '%s' "$drop_body" | sed 's/^/          /'
        fi
        armed_note="auto-resume: armed on UserPromptSubmit and StopFailure — remove it with uninstall.sh, or re-run with --no-rewake"
        if [ "$dry_run" = 1 ]; then
            plan "settings.json: the merge would change $settings:"
            diff <(printf '%s' "$cur_json" | jq -S .) <(printf '%s\n' "$merged" | jq -S .)
            [ "$rewake" = true ] && plan "auto-resume: would arm the waiter on UserPromptSubmit and StopFailure"
        elif [ "$(printf '%s' "$cur_json" | jq -S .)" = "$(printf '%s\n' "$merged" | jq -S .)" ]; then
            skipstep "settings.json: already carries exactly this — nothing written"
            [ "$rewake" = true ] && ok "$armed_note"
        # Claude Code rewrites this file at runtime (enabledPlugins, autoMode,
        # modelSettings), so between the read above and the write below someone
        # else may have changed it. Compare, do not lock: refusing costs a
        # re-run, clobbering costs the other writer's edit.
        elif [ "$(cat "$settings" 2>/dev/null)" != "$cur_json" ]; then
            refuse "$settings changed while this run was computing its merge — nothing was written" \
                   "close Claude Code (it rewrites this file at runtime) and re-run"
        else
            # The backup goes through a tmp of its own: cp truncates its
            # destination before writing, so a cp that fails part way would
            # otherwise leave an empty file at the canonical backup path, on top
            # of a good backup from an earlier run.
            if cp -p "$settings" "$settings.session-bak.tmp" \
                && mv -f "$settings.session-bak.tmp" "$settings.session-bak" \
                && printf '%s\n' "$merged" > "$settings.session-tmp" \
                && mv -f "$settings.session-tmp" "$settings"; then
                ok "settings.json: updated (previous copy at $settings.session-bak)"
                [ "$rewake" = true ] && ok "$armed_note"
            else
                rm -f "$settings.session-bak.tmp" "$settings.session-tmp"
                refuse "cannot write $settings" "$WRITE_REMEDY"
            fi
        fi
    fi
fi

# A dry run is a preview of changes and stops here: the focus-tracking lines
# below and `session doctor` describe an install that has not happened.
if [ "$dry_run" = 1 ]; then
    printf '\nDry run: nothing was written.\n'
    [ "$refused" -eq 0 ] || { printf '%s step(s) would refuse.\n' "$refused"; exit 1; }
    exit 0
fi

# ── 8. what only you can wire ────────────────────────────────────────────────
# Neither a tmux config nor a crontab is ever edited here: both are files a
# person owns and re-sources by hand, and a half-applied edit to either is worse
# than a line you paste yourself.
cat <<FOCUSEOF

Focus tracking is optional and needs two things this installer will not edit for
you. In ~/.tmux.conf (then \`tmux source-file ~/.tmux.conf\`):

  set-hook -g "client-focus-in[0]"        "run-shell -b '$link --focus-mark in  #{hook_client}'"
  set-hook -g "client-focus-out[0]"       "run-shell -b '$link --focus-mark out #{hook_client}'"
  set-hook -g "client-detached[0]"        "run-shell -b '$link --focus-mark out #{hook_client}'"
  set-hook -g "session-window-changed[0]" "run-shell -b '$link --focus-mark switch #{hook_session_name}'"

And in your crontab (\`crontab -e\`), the one-a-minute attention tick:

  * * * * * $link --focus-mark tick

Without them everything still works: attended time falls back to active time and
says so (attended_basis).

Restart Claude Code for the hook and statusLine entries to take effect.

FOCUSEOF

printf -- '--- session doctor ---\n'
"$CLI" doctor
printf -- '--- end of doctor (its status is not this installer status) ---\n'

if [ "$refused" -gt 0 ]; then
    printf '\n%s step(s) refused. Everything else was applied.\n' "$refused"
    exit 1
fi
printf '\nInstalled.\n'
exit 0
