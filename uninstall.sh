#!/usr/bin/env bash
# uninstall.sh — undo what install.sh wired, and nothing else.
#
# Removes from $CLAUDE_CONFIG_DIR/settings.json this clone's hook entries (the
# eight lifecycle ones and the two auto-resume ones) and the statusLine when it
# is ours; unlinks the CLI when the name points at this clone. An entry
# belonging to ANOTHER clone of this CLI goes too, but only when its command has
# the exact shape install.sh writes — a foreign command that merely mentions the
# same words is not ours to delete. A foreign statusLine, a symlink pointing
# elsewhere, a hook group we did not empty and every other setting are left
# exactly as they are, and a second run changes nothing.
#
# What it deliberately does NOT remove: the usage data root (your recorded
# history — the command to delete it is printed) and session.conf (it describes
# the machine, not the install).
set -uo pipefail

usage() {
    cat <<'USAGEEOF'
usage: uninstall.sh [--bindir DIR] [--name NAME]

  --bindir DIR   where the CLI was linked (default: ~/.local/bin)
  --name NAME    the name it was linked as (default: session)

When nothing of ours is at --bindir, whatever `name` resolves to on PATH is
checked as a fallback, so an install into a directory you no longer remember is
still found — but a second wiring of the same clone is never swept from beside
a live one.
USAGEEOF
}

bindir=""
name="session"
while [ $# -gt 0 ]; do
    case "$1" in
        --bindir|--name)
            [ $# -ge 2 ] || { echo "uninstall.sh: $1 needs a value" >&2; exit 2; }
            case "$1" in
                --bindir) bindir="$2" ;;
                --name)   name="$2" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "uninstall.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    esac
done

# Run directly from the clone, like install.sh: no symlink walk, just a loud
# refusal if someone links it, because through a link SESSION_HOME would name
# the wrong directory and this script decides what to delete by comparing paths.
if [ -L "${BASH_SOURCE[0]}" ]; then
    echo "uninstall.sh: run me directly from the clone, not through the symlink ${BASH_SOURCE[0]}" >&2
    echo "              I decide what to remove by comparing paths against the directory I am in." >&2
    exit 1
fi
case "${BASH_SOURCE[0]}" in
    */*) SESSION_HOME=$(cd -P "${BASH_SOURCE[0]%/*}" && pwd -P) ;;
    *)   SESSION_HOME=$(pwd -P) ;;
esac
. "$SESSION_HOME/lib/common.sh" || { echo "uninstall.sh: cannot read $SESSION_HOME/lib/common.sh" >&2; exit 1; }

CLI="$SESSION_HOME/session"
LINE="$SESSION_HOME/statusline.sh"
NL='
'

refused=0
ok()       { printf 'ok      %s\n' "$1"; }
skipstep() { printf 'skip    %s\n' "$1"; }
# Counts here rather than at each call site, which is install.sh's idiom and the
# one that cannot be forgotten at a seventh call site.
refuse()   { refused=$((refused + 1)); printf 'REFUSE  %s\n        %s\n' "$1" "$2"; }

settings="$SESSION_CFG/settings.json"
[ -L "$settings" ] && settings=$(realpath_of "$settings")

# The path out of a command of the shape install.sh writes. Read off the shape,
# never by word-splitting: a clone path containing a space would otherwise yield
# a fragment, and this script deletes what it matches.
_entry_path() {
    local c="$1"
    case "$c" in "bash "*) c=${c#bash } ;; esac
    case "$c" in *" --"*) c=${c%%" --"*} ;; *) return 1 ;; esac
    case "$c" in /*) printf '%s' "$c"; return 0 ;;
                 '~'/*) printf '%s%s' "$HOME" "${c#\~}"; return 0 ;; esac
    return 1
}

if [ ! -e "$settings" ]; then
    skipstep "settings.json: $settings does not exist"
elif ! command -v jq >/dev/null 2>&1; then
    refuse "jq is not installed, and every settings.json edit here goes through it" \
           "install jq and re-run"
elif [ ! -r "$settings" ]; then
    refuse "$settings exists but cannot be read" \
           "make it readable (chmod u+r) and re-run; it is left untouched"
elif ! jq . "$settings" >/dev/null 2>&1; then
    refuse "$settings is not valid JSON" "fix or move the file (it is left untouched) and re-run"
else
    drop_statusline=false
    sl_type=$(jq -r '.statusLine | type' "$settings")
    if [ "$sl_type" = "object" ]; then
        cur_sl=$(jq -r '.statusLine.command // empty' "$settings")
        sl_path="$cur_sl"
        case "$sl_path" in "bash "*) sl_path=${sl_path#bash } ;; esac
        case "$sl_path" in '~'/*) sl_path="$HOME${sl_path#\~}" ;; esac
        if [ -n "$cur_sl" ] && [ "$(realpath_of "$sl_path")" = "$(realpath_of "$LINE")" ]; then
            drop_statusline=true
        elif [ -n "$cur_sl" ]; then
            skipstep "statusLine: left alone, it is not ours ($cur_sl)"
        fi
    elif [ "$sl_type" != "null" ]; then
        skipstep "statusLine: left alone, it is not an object ($sl_type)"
    fi

    # Ours by path equality — the same test install.sh uses for its own entries,
    # so a clone whose directory is not named `session` can still be uninstalled.
    # Another clone's entries go too, but only on the exact written shape,
    # anchored at both ends: `echo my-rewake-waiter-notes.txt` and
    # `grep -r "/session/session --" …` are commands, not installs. It is the
    # same pattern install.sh drops a DEAD entry on, so the two scripts cannot
    # disagree about what another clone's entry looks like — `~/…` included,
    # which _entry_path has already expanded and which a hand-deployed settings
    # file may write in tilde form.
    drop_body=""
    while IFS= read -r c; do
        [ -n "$c" ] || continue
        p=$(_entry_path "$c") || continue
        if [ "$p" = "$CLI" ]; then
            drop_body="$drop_body$c$NL"
            continue
        fi
        case "$c" in
            "bash "*"/session/session --"*) drop_body="$drop_body$c$NL" ;;
        esac
    done <<DROPEOF
$(jq -r '[.hooks[]?[]?.hooks[]? | .command // empty] | .[]' "$settings")
DROPEOF
    drop=$(printf '%s' "$drop_body" | jq -R -s 'split("\n") | map(select(length > 0))')
    n=$(printf '%s' "$drop_body" | grep -c . )

    # Only groups carrying a hooks array are touched, and one rule at all three
    # levels: a group, an event key and the hooks object itself are dropped only
    # when THIS run emptied them. A husk somebody else left is theirs, and the
    # event keys install.sh created are ours to take back — leaving them made an
    # install/uninstall round trip on `{}` end at eight empty arrays.
    merged=$(jq --argjson dropline "$drop_statusline" --argjson drop "$drop" '
        (.hooks // {}) as $was
        | (has("hooks") and ($was | length) == 0) as $keep_empty
        | .hooks = ($was
                  | with_entries(.value |= (map(if (.hooks | type) == "array"
                                                then (.hooks | length) as $before
                                                     | .hooks |= map(select(. as $e | ($drop | index($e.command // "")) | not))
                                                     | select((.hooks | length) > 0 or $before == 0)
                                                else . end)))
                  | with_entries(select((.value | length) > 0 or ($was[.key] | length) == 0)))
        | (if (.hooks | length) == 0 and ($keep_empty | not) then del(.hooks) else . end)
        | (if $dropline then del(.statusLine) else . end)' "$settings")

    if [ -z "$merged" ]; then
        refuse "the settings edit produced nothing" "report the output; $settings is untouched"
    elif [ "$(jq -S . "$settings")" = "$(printf '%s\n' "$merged" | jq -S .)" ]; then
        skipstep "settings.json: carries nothing of ours"
    else
        what=""
        [ "$n" -gt 0 ] && what="$n hook entr$([ "$n" = 1 ] && echo y || echo ies)"
        [ "$drop_statusline" = true ] && what="${what:+$what, }the statusLine"
        if cp -p "$settings" "$settings.session-bak.tmp" \
            && mv -f "$settings.session-bak.tmp" "$settings.session-bak" \
            && printf '%s\n' "$merged" > "$settings.session-tmp" \
            && mv -f "$settings.session-tmp" "$settings"; then
            ok "settings.json: removed ${what:-nothing but empty scaffolding} (previous copy at $settings.session-bak)"
        else
            rm -f "$settings.session-bak.tmp" "$settings.session-tmp"
            refuse "cannot write $settings" \
                   "check that $SESSION_CFG is writable, the filesystem is not read-only and the disk is not full"
        fi
    fi
fi

# The symlink: the named one, plus whatever the name resolves to on PATH — an
# install into a directory nobody remembers is still found that way.
bindir="${bindir:-$SESSION_BINDIR_DEFAULT}"
targets="$bindir/$name"
# The PATH sweep is a FALLBACK for an install whose bindir nobody remembers.
# When the named link is already this clone's, a second wiring of the same
# clone elsewhere on PATH belongs to another install and is not this run's to
# remove (a scratch install's uninstall once reaped the production link that
# shared its clone, 2026-08-31).
if { [ -e "$bindir/$name" ] || [ -L "$bindir/$name" ]; } \
   && [ "$(realpath_of "$bindir/$name")" = "$(realpath_of "$CLI")" ]; then
    :
else
    onpath=$(command -v "$name" 2>/dev/null || true)
    case "$onpath" in
        ""|"$bindir/$name") ;;
        *) targets="$targets$NL$onpath" ;;
    esac
fi
removed=0
while IFS= read -r t; do
    [ -n "$t" ] || continue
    [ -e "$t" ] || [ -L "$t" ] || continue
    if [ "$(realpath_of "$t")" = "$(realpath_of "$CLI")" ]; then
        rm -f "$t" && { ok "CLI: removed $t"; removed=1; } \
            || refuse "cannot remove $t" "remove it by hand"
    else
        skipstep "CLI: $t points elsewhere, left alone"
    fi
done <<TARGETSEOF
$targets
TARGETSEOF
[ "$removed" = 1 ] || skipstep "CLI: no symlink of ours found under $bindir"

printf '\n'
if [ -d "$SESSION_DATA" ]; then
    printf 'Your recorded usage history is left in place. To delete it:\n  rm -rf %s\n' "$SESSION_DATA"
fi
if [ -e "$SESSION_CFG/session.conf" ]; then
    printf 'session.conf is left in place (it describes this machine, not the install):\n  %s\n' "$SESSION_CFG/session.conf"
fi
printf 'Restart Claude Code for the removal to take effect.\n'

[ "$refused" -eq 0 ]
