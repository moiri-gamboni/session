#!/usr/bin/env bash
# Suite for the installer: bash tests/install.test.sh
#
# Cases 26-29: the installer and the uninstaller. Every case runs against a scratch
# CLAUDE_CONFIG_DIR under mktemp, with a fake HOME, a fake `claude` on PATH (the
# version the rewake gate probes) and its own bindir: no case reads or writes the
# real config dir, the real ~/bin or the real usage store, and none of them runs
# the installer against a live Claude Code configuration.
#
# jq is a hard dependency of the installer, so this whole suite skips where jq is
# absent. session.test.sh cases 1 and 13 lint install.sh and uninstall.sh too.
#
# Note what case 26 pins by asserting exit 0: the installer's last step runs
# `session doctor`, which does not exist until the CLI unit lands, so in a
# worktree carrying the unmodified import that command exits 2. The installer's
# own status must reflect its own steps only.
set -uo pipefail

SUITE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SDIR=$(dirname "$SUITE")

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

if ! have jq; then
    skip "cases 26-29" "no jq — the installer requires it; the lint cases still run in session.test.sh"
    echo
    echo "$pass passed, $fail failed, $skipped skipped"
    exit 0
fi

TMP=$(mktemp -d)
FH="$TMP/home"; mkdir -p "$FH"
cleanup() {
    # The ownership case makes one directory root-owned; give it back before the
    # recursive remove, or the tree survives the suite.
    [ -n "${NOTMINE:-}" ] && [ -d "$NOTMINE" ] && sudo -n chown -R "$(id -u)" "$NOTMINE" >/dev/null 2>&1
    rm -rf "$TMP"
}
trap cleanup EXIT

# Every case installs from a COPY of the session directory, not from the
# checkout: the installer refuses a directory the running uid does not own, and a
# copy the running user just made is always its own. It also means no fixture
# can write through a symlink into a shipped file.
# The copy keeps the real shape — a directory named `session` holding the CLI —
# because the batch contract's ownership regex (`/session/session --`) reads the
# path, so a copy under any other name would test a shape that never ships.
CLONE="$TMP/clone/session"
mkdir -p "$TMP/clone"
cp -R "$SDIR" "$CLONE" || { echo "cannot copy $SDIR" >&2; exit 2; }
INSTALL="$CLONE/install.sh"
UNINSTALL="$CLONE/uninstall.sh"
SESSION_BIN="$CLONE/session"
STATUSLINE="$CLONE/statusline.sh"

FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/claude" <<'CLAUDEEOF'
#!/bin/sh
printf '%s (Claude Code)\n' "${FAKE_CLAUDE_VERSION:-2.1.251}"
CLAUDEEOF
chmod +x "$FAKEBIN/claude"

FAKE_CLAUDE_VERSION=2.1.251
IHOME="$FH"
IPATH="$FAKEBIN:$PATH"

# Runs the installer in isolation. `env -i` so the outer session's own
# CLAUDE_CONFIG_DIR, SESSION_DATA_DIR and login never reach it; stderr is folded
# in because a refusal's remedy is part of what the cases read.
inst() {  # inst CFGDIR [args...]
    local cfg="$1"; shift
    env -i PATH="$IPATH" HOME="$IHOME" \
        FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
        CLAUDE_CONFIG_DIR="$cfg" bash "$INSTALL" "$@" 2>&1
}
uninst() {  # uninst CFGDIR [args...]
    local cfg="$1"; shift
    env -i PATH="$IPATH" HOME="$IHOME" \
        CLAUDE_CONFIG_DIR="$cfg" bash "$UNINSTALL" "$@" 2>&1
}

mkcfg() { mktemp -d "$TMP/cfg.XXXXXX"; }

# Guard against the hazard the foreign-file fixtures carry: `> "$bindir/session"`
# writes THROUGH a symlink into the real CLI. Checksums are taken now and
# compared at the end.
shipped_sums() { cksum "$SDIR/session" "$SDIR/statusline.sh" "$SDIR/install.sh" "$SDIR/uninstall.sh" 2>/dev/null; }
SHIPPED_BEFORE=$(shipped_sums)
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

# A case that makes a fixture fail by taking a permission bit away proves
# nothing where the bits do not bite — a run as root
# reads a mode-000 file and writes into a mode-500 directory. Those cases say so
# rather than passing, or failing, for the wrong reason.
perms_bite() { [ "$(id -u)" != 0 ]; }
ROOT_SKIP="running as root: a permission bit denies nothing, so the case cannot fail the way it is meant to"

# The two ownership shapes, as the batch contract defines them.
LIFECYCLE='[.hooks[]?[]?.hooks[]? | select((.command|test("/session/session --")) and (.command|test("rewake-waiter")|not))]'
REWAKE='[.hooks[]?[]?.hooks[]? | select(.command|test("rewake-waiter"))]'

echo "--- case 26: a fresh install ---"

C26=$(mkcfg); B26="$TMP/bin26"
out=$(inst "$C26" --bindir "$B26"); rc=$?
S26="$C26/settings.json"

report 0 "$rc" "case 26: exit 0 (the installer's status is its own steps', not \`session doctor\`'s)"
report yes "$(yesno test -f "$S26")" "case 26: settings.json exists"

report 8 "$(jq "$LIFECYCLE | length" "$S26")" "case 26: eight lifecycle entries"
report 8 "$(jq "$LIFECYCLE | map(select(.command|endswith(\"|| true\"))) | length" "$S26")" \
    "case 26: every lifecycle entry ends with || true"
report 8 "$(jq "$LIFECYCLE | map(select(.timeout==2)) | length" "$S26")" \
    "case 26: every lifecycle entry has timeout 2"
report 8 "$(jq "$LIFECYCLE | map(select(.type==\"command\")) | length" "$S26")" \
    "case 26: every lifecycle entry is type command"

for pair in "UserPromptSubmit --hook" "Stop --turn-end" "StopFailure --turn-fail" \
            "SessionEnd --session-end" "SubagentStart --subagent-start" \
            "SubagentStop --subagent-end" "PostCompact --compact-mark" \
            "Notification --perm-mark"; do
    ev=${pair%% *}; mode=${pair#* }
    want="bash $SESSION_BIN $mode || true"
    report 1 "$(jq --arg e "$ev" --arg c "$want" '[.hooks[$e][]?.hooks[]? | select(.command == $c)] | length' "$S26")" \
        "case 26: $ev carries \`$want\`"
done

report "permission_prompt" \
    "$(jq -r '.hooks.Notification[] | select(any(.hooks[]; .command|test("--perm-mark"))) | .matcher' "$S26")" \
    "case 26: --perm-mark sits under matcher permission_prompt"
report "null" \
    "$(jq -r '.hooks.UserPromptSubmit[] | select(any(.hooks[]; .command|test("--hook"))) | .matcher // "null"' "$S26")" \
    "case 26: the lifecycle groups on other events carry no matcher"

report 2 "$(jq "$REWAKE | length" "$S26")" "case 26: two rewake entries"
report 2 "$(jq "$REWAKE | map(select(.asyncRewake == true)) | length" "$S26")" \
    "case 26: both rewake entries are asyncRewake"
report 2 "$(jq "$REWAKE | map(select(.timeout == 700000)) | length" "$S26")" \
    "case 26: both rewake entries have timeout 700000"
report 0 "$(jq "$REWAKE | map(select(.command|test(\"\\\\|\\\\| true\"))) | length" "$S26")" \
    "case 26: NEITHER rewake entry carries || true (exit 2 is the wake signal)"
report 2 "$(jq --arg c "bash $SESSION_BIN --rewake-waiter" "$REWAKE | map(select(.command == \$c)) | length" "$S26")" \
    "case 26: both rewake commands are exactly \`bash $SESSION_BIN --rewake-waiter\`"
# Presence, not wording: these two are display strings (their exact text lives
# in a code comment at install.sh's constants). A wake with no message is the
# behavioural failure; a better phrasing is not.
report 2 "$(jq "$REWAKE | map(select(.rewakeMessage != null and .rewakeSummary != null)) | length" "$S26")" \
    "case 26: both rewake entries carry a wake message and a summary"
report "StopFailure UserPromptSubmit" \
    "$(jq -r '[.hooks|to_entries[]|select(any(.value[].hooks[]?; .command|test("rewake-waiter")))|.key]|sort|join(" ")' "$S26")" \
    "case 26: the rewake pair sits on UserPromptSubmit and StopFailure"

report "bash $STATUSLINE" "$(jq -r '.statusLine.command' "$S26")" "case 26: statusLine command"
report "command" "$(jq -r '.statusLine.type' "$S26")" "case 26: statusLine type"
report "10" "$(jq -r '.statusLine.refreshInterval' "$S26")" "case 26: statusLine refreshInterval"

report "hooks statusLine" "$(jq -r 'keys | join(" ")' "$S26")" "case 26: hooks and statusLine are the only top-level keys added"

report yes "$(yesno test -L "$B26/session")" "case 26: the CLI symlink exists"
report "$SESSION_BIN" "$(readlink "$B26/session")" "case 26: ... and points at this clone's session"

report yes "$(yesno test -d "$C26/session-usage")" "case 26: the data root is created"
report 700 "$(mode_of "$C26/session-usage")" "case 26: the data root is 700"
report "*" "$(cat "$C26/session-usage/.gitignore" 2>/dev/null)" "case 26: the data root carries a .gitignore of *"
report 600 "$(mode_of "$C26/session-usage/.gitignore")" "case 26: files under the data root are 600"
report yes "$(yesno test -d "$C26/session-usage/sessions")" "case 26: the snapshot dir is created"

report absent "$([ -e "$C26/session.conf" ] && echo present || echo absent)" \
    "case 26: no session.conf when none of the five conf flags was passed"

# --data-dir + --main-guard: the shape of a machine whose data lives elsewhere.
C26b=$(mkcfg); B26b="$TMP/bin26b"; D26="$TMP/data26"; G26="$TMP/guard26.sh"
: > "$G26"; chmod +x "$G26"
out=$(inst "$C26b" --bindir "$B26b" --data-dir "$D26" --main-guard "$G26"); rc=$?
report 0 "$rc" "case 26 [conf]: exit 0"
report yes "$(yesno test -f "$C26b/session.conf")" "case 26 [conf]: session.conf is written"
report 2 "$(grep -c '^SESSION_' "$C26b/session.conf")" \
    "case 26 [conf]: exactly the two flags passed, one line each"
report yes "$(yesno grep -qxF "SESSION_DATA_DIR=\"\${SESSION_DATA_DIR:-$D26}\"" "$C26b/session.conf")" \
    "case 26 [conf]: the SESSION_DATA_DIR line is in the \${VAR:-value} form"
report yes "$(yesno grep -qxF "SESSION_TMUX_MAIN_GUARD=\"\${SESSION_TMUX_MAIN_GUARD:-$G26}\"" "$C26b/session.conf")" \
    "case 26 [conf]: the SESSION_TMUX_MAIN_GUARD line likewise"
report yes "$(yesno test -d "$D26")" "case 26 [conf]: the data root is created at --data-dir"
report 700 "$(mode_of "$D26")" "case 26 [conf]: ... with mode 700"
report absent "$([ -e "$C26b/session-usage" ] && echo present || echo absent)" \
    "case 26 [conf]: ... and no stray session-usage/ beside it"

# The home-prefix substitution: a value under $HOME is written as the literal
# $HOME, so a conf kept in a dotfiles repository reads the same on every machine.
C26c=$(mkcfg); B26c="$TMP/bin26c"
out=$(inst "$C26c" --bindir "$B26c" --data-dir "$FH/somewhere/usage" --primary-cfg "$FH/somewhere/claude" \
      --attend-grace 900)
report yes "$(yesno grep -qxF 'SESSION_DATA_DIR="${SESSION_DATA_DIR:-$HOME/somewhere/usage}"' "$C26c/session.conf")" \
    "case 26 [conf]: a value under \$HOME is written as the literal \$HOME"
report yes "$(yesno grep -qxF 'SESSION_PRIMARY_CFG="${SESSION_PRIMARY_CFG:-$HOME/somewhere/claude}"' "$C26c/session.conf")" \
    "case 26 [conf]: --primary-cfg adds its line"
report yes "$(yesno grep -qxF 'SESSION_ATTEND_GRACE="${SESSION_ATTEND_GRACE:-900}"' "$C26c/session.conf")" \
    "case 26 [conf]: --attend-grace adds its line"
report 3 "$(grep -c '^SESSION_' "$C26c/session.conf")" "case 26 [conf]: and nothing else"

# --no-rewake
C26d=$(mkcfg); B26d="$TMP/bin26d"
out=$(inst "$C26d" --bindir "$B26d" --no-rewake); rc=$?
report 0 "$rc" "case 26 [--no-rewake]: exit 0"
report 8 "$(jq "$LIFECYCLE | length" "$C26d/settings.json")" "case 26 [--no-rewake]: the eight lifecycle entries"
report 0 "$(jq "$REWAKE | length" "$C26d/settings.json")" "case 26 [--no-rewake]: no rewake entry"

# --dry-run writes nothing at all
C26e=$(mkcfg); B26e="$TMP/bin26e"; D26e="$TMP/data26e"
out=$(inst "$C26e" --bindir "$B26e" --dry-run --data-dir "$D26e"); rc=$?
report 0 "$rc" "case 26 [--dry-run]: exit 0"
report absent "$([ -e "$C26e/settings.json" ] && echo present || echo absent)" "case 26 [--dry-run]: no settings.json"
report absent "$([ -e "$C26e/session.conf" ] && echo present || echo absent)" "case 26 [--dry-run]: no session.conf"
report absent "$([ -e "$D26e" ] && echo present || echo absent)" "case 26 [--dry-run]: no data root"
report absent "$([ -e "$B26e/session" ] && echo present || echo absent)" "case 26 [--dry-run]: no symlink"
report yes "$(yesno grep -q 'statusLine' <<<"$out")" "case 26 [--dry-run]: the diff shows the statusLine it would add"
report yes "$(yesno grep -q -- '--rewake-waiter' <<<"$out")" "case 26 [--dry-run]: ... and the rewake entries"
# `<`/`>` is GNU diff's default, `+`/`-` is busybox's unified default: assert a
# changed line carrying our content, not one implementation's marker.
report yes "$(yesno grep -qE '^[<>+].*(--hook|statusLine)' <<<"$out")" "case 26 [--dry-run]: the output is a diff"

echo "--- case 27: a second run is a byte-identical no-op ---"

cp "$S26" "$TMP/before27"
out=$(inst "$C26" --bindir "$B26"); rc=$?
report 0 "$rc" "case 27: exit 0"
report yes "$(yesno cmp -s "$TMP/before27" "$S26")" "case 27: settings.json is byte-identical"
report yes "$(yesno grep -q 'skip' <<<"$out")" "case 27: the settings step reports skip"
report "{}" "$(jq -c . "$C26/settings.json.session-bak")" \
    "case 27: the backup still holds the pre-install {} — a no-op writes no new backup"
report yes "$(yesno test -L "$B26/session")" "case 27: the symlink is still ours"

echo "--- case 28: refusals ---"

# (a) a foreign statusLine is named, printed, and never overwritten — while the
# rest of the merge still lands.
C28a=$(mkcfg); B28a="$TMP/bin28a"
cat > "$C28a/settings.json" <<'FOREIGNEOF'
{"statusLine":{"type":"command","command":"bash /opt/other/line.sh","refreshInterval":5}}
FOREIGNEOF
out=$(inst "$C28a" --bindir "$B28a"); rc=$?
report 1 "$rc" "case 28 [statusLine]: exit 1"
report yes "$(yesno grep -q 'REFUSE' <<<"$out")" "case 28 [statusLine]: a REFUSE line"
report yes "$(yesno grep -q '/opt/other/line.sh' <<<"$out")" "case 28 [statusLine]: it names the foreign command"
report yes "$(yesno grep -q "$STATUSLINE" <<<"$out")" "case 28 [statusLine]: it prints the object to merge by hand"
report "bash /opt/other/line.sh" "$(jq -r '.statusLine.command' "$C28a/settings.json")" \
    "case 28 [statusLine]: the foreign statusLine is untouched"
report 8 "$(jq "$LIFECYCLE | length" "$C28a/settings.json")" \
    "case 28 [statusLine]: the refusal did not stop the hook entries"
report yes "$(yesno test -L "$B28a/session")" "case 28 [statusLine]: nor the symlink"

# (b) the name is taken by a foreign file
C28b=$(mkcfg); B28b="$TMP/bin28b"; mkdir -p "$B28b"
rm -f "$B28b/session"   # never write THROUGH it: after --force-link it is a symlink to the real CLI
printf '#!/bin/sh\necho foreign\n' > "$B28b/session"; chmod +x "$B28b/session"
out=$(inst "$C28b" --bindir "$B28b"); rc=$?
report 1 "$rc" "case 28 [name taken]: exit 1"
report yes "$(yesno grep -q 'REFUSE' <<<"$out")" "case 28 [name taken]: a REFUSE line"
report yes "$(yesno grep -q -- '--force-link' <<<"$out")" "case 28 [name taken]: the remedy names --force-link"
report yes "$(yesno grep -q -- '--name' <<<"$out")" "case 28 [name taken]: ... and --name"
report no "$(yesno test -L "$B28b/session")" "case 28 [name taken]: the foreign file is left alone"
report 8 "$(jq "$LIFECYCLE | length" "$C28b/settings.json")" \
    "case 28 [name taken]: the settings steps still ran"

out=$(inst "$C28b" --bindir "$B28b" --force-link); rc=$?
report 0 "$rc" "case 28 [--force-link]: exit 0"
report "$SESSION_BIN" "$(readlink "$B28b/session")" "case 28 [--force-link]: the name is taken over"

rm -f "$B28b/session"   # never write THROUGH it: after --force-link it is a symlink to the real CLI
printf '#!/bin/sh\necho foreign\n' > "$B28b/session"; chmod +x "$B28b/session"
out=$(inst "$C28b" --bindir "$B28b" --name other); rc=$?
report 0 "$rc" "case 28 [--name]: exit 0"
report "$SESSION_BIN" "$(readlink "$B28b/other")" "case 28 [--name]: the alternative name is linked"
report no "$(yesno test -L "$B28b/session")" "case 28 [--name]: and the taken name is left alone"

# (c) a name pointing at a copy of this CLI deployed under some other config
# directory is a foreign link like any other: taking it over needs --force-link.
C28c=$(mkcfg); B28c="$TMP/bin28c"; mkdir -p "$B28c"
LEGACY="$TMP/legacy/claude/scripts/session.sh"
mkdir -p "$(dirname "$LEGACY")"; printf '#!/bin/sh\n' > "$LEGACY"; chmod +x "$LEGACY"
ln -sfn "$LEGACY" "$B28c/session"
out=$(inst "$C28c" --bindir "$B28c"); rc=$?
report 1 "$rc" "case 28 [deployed copy]: exit 1 — a refusal"
report "$LEGACY" "$(readlink "$B28c/session")" "case 28 [deployed copy]: the link is left alone"
report yes "$(yesno grep -q -- '--force-link' <<<"$out")" "case 28 [deployed copy]: the remedy names --force-link"

# (d) running from under a plugin cache
C28d=$(mkcfg); B28d="$TMP/bin28d"
PCROOT="$TMP/plugins/cache/session"
mkdir -p "$PCROOT"
cp -R "$CLONE" "$PCROOT/session"
out=$(env -i PATH="$IPATH" HOME="$IHOME" FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
      CLAUDE_CONFIG_DIR="$C28d" bash "$PCROOT/session/install.sh" --bindir "$B28d" 2>&1); rc=$?
report 1 "$rc" "case 28 [plugin cache]: exit 1"
report yes "$(yesno grep -q 'REFUSE' <<<"$out")" "case 28 [plugin cache]: a REFUSE line"
report yes "$(yesno grep -q 'git clone' <<<"$out")" "case 28 [plugin cache]: the remedy is a clone"
report absent "$([ -e "$C28d/settings.json" ] && echo present || echo absent)" \
    "case 28 [plugin cache]: nothing was written"

# (e) the script directory is not ours. Faking this needs a second uid, so the
# case runs only where passwordless sudo can hand one over.
C28e=$(mkcfg); B28e="$TMP/bin28e"
if sudo -n true >/dev/null 2>&1; then
    NOTMINE="$TMP/notmine"
    cp -R "$CLONE" "$NOTMINE"
    sudo -n chown 0 "$NOTMINE" >/dev/null 2>&1
    if [ -O "$NOTMINE" ]; then
        skip "case 28 [ownership]" "chown left the directory ours (running as root?)"
    else
        out=$(env -i PATH="$IPATH" HOME="$IHOME" FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
              CLAUDE_CONFIG_DIR="$C28e" bash "$NOTMINE/install.sh" --bindir "$B28e" 2>&1); rc=$?
        report 1 "$rc" "case 28 [ownership]: exit 1"
        report yes "$(yesno grep -q 'REFUSE' <<<"$out")" "case 28 [ownership]: a REFUSE line"
        report absent "$([ -e "$C28e/settings.json" ] && echo present || echo absent)" \
            "case 28 [ownership]: nothing was written"
    fi
else
    skip "case 28 [ownership]" "no passwordless sudo to create a directory owned by another uid"
fi

# (f) an unparsable settings.json refuses the settings steps and nothing else
C28f=$(mkcfg); B28f="$TMP/bin28f"; D28f="$TMP/data28f"
printf 'not json at all\n' > "$C28f/settings.json"
out=$(inst "$C28f" --bindir "$B28f" --data-dir "$D28f"); rc=$?
report 1 "$rc" "case 28 [unparsable]: exit 1"
report yes "$(yesno grep -q 'REFUSE' <<<"$out")" "case 28 [unparsable]: a REFUSE line"
report "not json at all" "$(cat "$C28f/settings.json")" "case 28 [unparsable]: the file is left exactly as it was"
report yes "$(yesno test -L "$B28f/session")" "case 28 [unparsable]: the symlink step still ran"
report yes "$(yesno test -d "$D28f")" "case 28 [unparsable]: the data root step still ran"
report yes "$(yesno test -f "$C28f/session.conf")" "case 28 [unparsable]: the conf step still ran"

# (g) an absent settings.json is created as {} before the merge — the backup is
# the proof, since step 7 copies the file it is about to replace.
report "{}" "$(jq -c . "$C26d/settings.json.session-bak")" \
    "case 28 [absent settings]: an absent settings.json was created as {}"

# (h) the rewake version gate. 2.1.99 is deliberately a version that a string
# comparison would pass and an integer-tuple comparison refuses.
C28h=$(mkcfg); B28h="$TMP/bin28h"
FAKE_CLAUDE_VERSION=2.1.99
out=$(inst "$C28h" --bindir "$B28h"); rc=$?
FAKE_CLAUDE_VERSION=2.1.251
report 1 "$rc" "case 28 [old claude]: exit 1"
report yes "$(yesno grep -q 'REFUSE' <<<"$out")" "case 28 [old claude]: a REFUSE line"
report yes "$(yesno grep -q '2\.1\.233' <<<"$out")" "case 28 [old claude]: it names the version it needs"
report yes "$(yesno grep -q -- '--no-rewake' <<<"$out")" "case 28 [old claude]: the remedy names --no-rewake"
report 0 "$(jq "$REWAKE | length" "$C28h/settings.json")" "case 28 [old claude]: no rewake entry was armed"
report 8 "$(jq "$LIFECYCLE | length" "$C28h/settings.json")" \
    "case 28 [old claude]: the eight lifecycle entries were still written"

for v in 2.1.233 2.1.251 2.2.0 3.0.0 10.0.0; do
    C=$(mkcfg); B="$TMP/bin28v$v"
    FAKE_CLAUDE_VERSION="$v"
    out=$(inst "$C" --bindir "$B")
    report 2 "$(jq "$REWAKE | length" "$C/settings.json")" "case 28 [version $v]: the rewake pair is armed"
done
for v in 2.1.232 2.0.999 1.9.9; do
    C=$(mkcfg); B="$TMP/bin28w$v"
    FAKE_CLAUDE_VERSION="$v"
    out=$(inst "$C" --bindir "$B")
    report 0 "$(jq "$REWAKE | length" "$C/settings.json")" "case 28 [version $v]: the rewake pair is refused"
done
FAKE_CLAUDE_VERSION=2.1.251

# (i) no claude on PATH at all: the gate fails closed rather than arming the
# waiter against a harness whose backgrounding behaviour it could not check.
C28i=$(mkcfg); B28i="$TMP/bin28i"
# A symlink farm rather than a hardcoded /usr/bin:/bin, whose contents differ per
# distribution — on Alpine bash itself is not there, and the case would fail for
# the wrong reason.
MINBIN="$TMP/minbin"; mkdir -p "$MINBIN"
for t in bash sh jq sed ls cat id mkdir chmod ln rm mv cp diff dirname basename tr awk stat; do
    tp=$(command -v "$t") && ln -sf "$tp" "$MINBIN/$t"
done
# Probed in a fresh process: bash keeps a command hash, so `PATH=x command -v`
# can answer from a location the new PATH does not contain.
if env -i PATH="$MINBIN" sh -c 'command -v claude' >/dev/null 2>&1; then
    skip "case 28 [no claude]" "a claude is on the minimal PATH"
elif ! env -i PATH="$MINBIN" sh -c 'command -v jq' >/dev/null 2>&1; then
    skip "case 28 [no claude]" "jq is not on the minimal PATH either, so the case would prove nothing"
else
    out=$(env -i PATH="$MINBIN" HOME="$IHOME" CLAUDE_CONFIG_DIR="$C28i" \
          bash "$INSTALL" --bindir "$B28i" 2>&1); rc=$?
    report 1 "$rc" "case 28 [no claude]: exit 1"
    report 0 "$(jq "$REWAKE | length" "$C28i/settings.json")" "case 28 [no claude]: no rewake entry"
    report 8 "$(jq "$LIFECYCLE | length" "$C28i/settings.json")" "case 28 [no claude]: the lifecycle entries still land"
fi

# (j) a stale entry of ours whose file is gone is dropped; a live one belonging
# to another clone is left alone.
C28j=$(mkcfg); B28j="$TMP/bin28j"
OTHER="$TMP/otherclone/session"; mkdir -p "$OTHER"
printf '#!/bin/sh\n' > "$OTHER/session"; chmod +x "$OTHER/session"
cat > "$C28j/settings.json" <<STALEEOF
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"bash $TMP/gone/session/session --turn-end || true","timeout":2},
  {"type":"command","command":"bash $OTHER/session --turn-end || true","timeout":2},
  {"type":"command","command":"/opt/foreign/other.sh","timeout":9}
]}]}}
STALEEOF
out=$(inst "$C28j" --bindir "$B28j")
report 0 "$(jq --arg c "bash $TMP/gone/session/session --turn-end || true" \
    '[.hooks.Stop[].hooks[]|select(.command==$c)]|length' "$C28j/settings.json")" \
    "case 28 [stale]: an entry of ours whose file is gone is dropped"
report 1 "$(jq --arg c "bash $OTHER/session --turn-end || true" \
    '[.hooks.Stop[].hooks[]|select(.command==$c)]|length' "$C28j/settings.json")" \
    "case 28 [stale]: another clone's live entry is left alone"
report 1 "$(jq '[.hooks.Stop[].hooks[]|select(.command=="/opt/foreign/other.sh")]|length' "$C28j/settings.json")" \
    "case 28 [stale]: a foreign entry is left alone"

echo "--- case 29: uninstall ---"

C29=$(mkcfg); B29="$TMP/bin29"; D29="$TMP/data29"
cat > "$C29/settings.json" <<'PREEOF'
{
  "model": "opus",
  "env": {"OTHER": "keep"},
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "/opt/foreign/hook.sh", "timeout": 5}]}],
    "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "/opt/foreign/guard.sh"}]}]
  }
}
PREEOF
out=$(inst "$C29" --bindir "$B29" --data-dir "$D29"); rc=$?
report 0 "$rc" "case 29: the install it will undo exits 0"
report 8 "$(jq "$LIFECYCLE | length" "$C29/settings.json")" "case 29: eight lifecycle entries before uninstall"

out=$(uninst "$C29" --bindir "$B29"); rc=$?
report 0 "$rc" "case 29: uninstall exits 0"
report 0 "$(jq "$LIFECYCLE | length" "$C29/settings.json")" "case 29: no lifecycle entry survives"
report 0 "$(jq "$REWAKE | length" "$C29/settings.json")" "case 29: no rewake entry survives"
report 1 "$(jq '[.hooks.UserPromptSubmit[]?.hooks[]?|select(.command=="/opt/foreign/hook.sh")]|length' "$C29/settings.json")" \
    "case 29: the foreign UserPromptSubmit hook is intact"
report 1 "$(jq '[.hooks.PreToolUse[]?.hooks[]?|select(.command=="/opt/foreign/guard.sh")]|length' "$C29/settings.json")" \
    "case 29: the foreign PreToolUse hook is intact"
report "Bash" "$(jq -r '.hooks.PreToolUse[0].matcher' "$C29/settings.json")" "case 29: its matcher is intact"
report "null" "$(jq -r '.statusLine // "null"' "$C29/settings.json")" "case 29: our statusLine is gone"
report "keep" "$(jq -r '.env.OTHER' "$C29/settings.json")" "case 29: the rest of env is intact"
report "opus" "$(jq -r '.model' "$C29/settings.json")" "case 29: unrelated settings are intact"
report absent "$([ -e "$B29/session" ] && echo present || echo absent)" "case 29: the symlink is gone"
report yes "$(yesno test -d "$D29")" "case 29: the data root is left in place"
report yes "$(yesno grep -q "$D29" <<<"$out")" "case 29: ... and the output says how to remove it"
report yes "$(yesno test -f "$C29/session.conf")" "case 29: session.conf is left in place"
report yes "$(yesno grep -q 'session.conf' <<<"$out")" "case 29: ... and the output says so"

cp "$C29/settings.json" "$TMP/before29"
out=$(uninst "$C29" --bindir "$B29"); rc=$?
report 0 "$rc" "case 29: a second uninstall exits 0"
report yes "$(yesno cmp -s "$TMP/before29" "$C29/settings.json")" "case 29: ... and changes nothing"

# A foreign statusLine and a foreign symlink are not ours to remove.
C29b=$(mkcfg); B29b="$TMP/bin29b"
out=$(inst "$C29b" --bindir "$B29b")
jq '.statusLine = {"type":"command","command":"bash /opt/other/line.sh"}' "$C29b/settings.json" > "$TMP/t29b" \
    && mv "$TMP/t29b" "$C29b/settings.json"
ln -sfn /bin/echo "$B29b/session"
out=$(uninst "$C29b" --bindir "$B29b"); rc=$?
report 0 "$rc" "case 29 [foreign]: exit 0"
report "bash /opt/other/line.sh" "$(jq -r '.statusLine.command' "$C29b/settings.json")" \
    "case 29 [foreign]: a foreign statusLine is left alone"
report "/bin/echo" "$(readlink "$B29b/session")" "case 29 [foreign]: a symlink pointing elsewhere is left alone"
report 0 "$(jq "$LIFECYCLE | length" "$C29b/settings.json")" "case 29 [foreign]: our hooks are still removed"

# The round trip the README's verification recipe ends on. Entry counts pass over
# scaffolding the run itself created — the eight event keys install.sh adds and
# uninstall.sh emptied — so the assertion is the whole tree, not a count.
C29c=$(mkcfg); B29c="$TMP/bin29c"
printf '{}\n' > "$C29c/settings.json"
out=$(inst "$C29c" --bindir "$B29c")
out=$(uninst "$C29c" --bindir "$B29c"); rc=$?
report 0 "$rc" "case 29 [round trip]: uninstall exits 0"
report "{}" "$(jq -Sc . "$C29c/settings.json")" \
    "case 29 [round trip]: install then uninstall on {} leaves {} — no emptied event key survives"

# And the other half of the same rule the groups already follow: a key this run
# did not empty is not ours to drop, empty or not.
C29d=$(mkcfg); B29d="$TMP/bin29d"
printf '{"hooks":{"PreToolUse":[]}}\n' > "$C29d/settings.json"
out=$(inst "$C29d" --bindir "$B29d")
out=$(uninst "$C29d" --bindir "$B29d")
report '{"hooks":{"PreToolUse":[]}}' "$(jq -Sc . "$C29d/settings.json")" \
    "case 29 [round trip]: an event key that was already empty is left as it was"
# The rule is per RUN, so the empty hooks object has to be empty when THIS run
# starts: after an install it holds eight keys this run empties, and taking the
# husk with them is the point. Uninstalled on its own, it stays.
C29e=$(mkcfg); B29e="$TMP/bin29e"
printf '{"hooks":{},"model":"opus"}\n' > "$C29e/settings.json"
out=$(uninst "$C29e" --bindir "$B29e"); rc=$?
report 0 "$rc" "case 29 [round trip]: uninstall over nothing of ours exits 0"
report '{"hooks":{},"model":"opus"}' "$(jq -Sc . "$C29e/settings.json")" \
    "case 29 [round trip]: ... leaving an empty hooks object it did not empty"

# ═══════════════════════════════════════════════════════════════════════════
# Review-round cases. Each block names the finding it pins; every one of them
# failed against the pre-review scripts.
# ═══════════════════════════════════════════════════════════════════════════

# Runs the installer from a chosen working directory, for the relative-path
# cases: hooks and cron run from a directory nobody chooses, so a value that is
# only meaningful relative to the install's cwd is a silent data-loss bug.
inst_at() {  # inst_at CWD CFGDIR [args...]
    local cwd="$1" cfg="$2"; shift 2
    ( cd "$cwd" && env -i PATH="$IPATH" HOME="$IHOME" \
        FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
        CLAUDE_CONFIG_DIR="$cfg" bash "$INSTALL" "$@" 2>&1 )
}
# Sources a session.conf the way lib/common.sh does and prints one variable.
conf_value() {  # conf_value CONF VAR
    env -i HOME="$IHOME" bash -c '. "$1" 2>/dev/null; eval "printf %s \"\$$2\""' _ "$1" "$2"
}
# A clone at an arbitrary path, so the space-in-path and non-`session`-dirname
# shapes can be installed from.
mkclone() {  # mkclone DIR   (DIR is the directory that will hold the CLI)
    mkdir -p "$(dirname "$1")" && cp -R "$CLONE" "$1"
}

echo "--- case F1: a re-run keeps the session.conf values this run does not carry ---"

CF1=$(mkcfg); BF1="$TMP/binf1"; DF1="$TMP/dataf1"; GF1="$TMP/guardf1.sh"; : > "$GF1"
out=$(inst "$CF1" --bindir "$BF1" --data-dir "$DF1")
report yes "$(yesno grep -qxF "SESSION_DATA_DIR=\"\${SESSION_DATA_DIR:-$DF1}\"" "$CF1/session.conf")" \
    "case F1: run 1 records the data root"

out=$(inst "$CF1" --bindir "$BF1" --main-guard "$GF1"); rc=$?
report 0 "$rc" "case F1: run 2 (a different flag) exits 0"
report yes "$(yesno grep -qxF "SESSION_DATA_DIR=\"\${SESSION_DATA_DIR:-$DF1}\"" "$CF1/session.conf")" \
    "case F1: run 2 keeps the data root it did not carry"
report yes "$(yesno grep -qxF "SESSION_TMUX_MAIN_GUARD=\"\${SESSION_TMUX_MAIN_GUARD:-$GF1}\"" "$CF1/session.conf")" \
    "case F1: ... and adds the guard it did carry"
report "$DF1" "$(conf_value "$CF1/session.conf" SESSION_DATA_DIR)" \
    "case F1: sourcing the merged conf yields the recorded data root"
report 2 "$(grep -c '^SESSION_' "$CF1/session.conf")" "case F1: exactly the two recorded variables"

out=$(inst "$CF1" --bindir "$BF1" --primary-cfg "$TMP/primaryf1")
report 3 "$(grep -c '^SESSION_' "$CF1/session.conf")" "case F1: run 3 accumulates the third"
report yes "$(yesno grep -qxF "SESSION_DATA_DIR=\"\${SESSION_DATA_DIR:-$DF1}\"" "$CF1/session.conf")" \
    "case F1: ... still keeping the first"

# A flag that IS carried overrides the recorded value rather than duplicating it.
DF1b="$TMP/dataf1b"
out=$(inst "$CF1" --bindir "$BF1" --data-dir "$DF1b")
report 1 "$(grep -c '^SESSION_DATA_DIR=' "$CF1/session.conf")" "case F1: a carried flag replaces, never duplicates"
report "$DF1b" "$(conf_value "$CF1/session.conf" SESSION_DATA_DIR)" "case F1: ... with the new value"
report 3 "$(grep -c '^SESSION_' "$CF1/session.conf")" "case F1: ... and the other two survive"

# The rule that must not regress: with no conf flag at all, an existing conf is
# left alone and no conf is created where there is none.
cp "$CF1/session.conf" "$TMP/conf-before-f1"
out=$(inst "$CF1" --bindir "$BF1")
report yes "$(yesno cmp -s "$TMP/conf-before-f1" "$CF1/session.conf")" \
    "case F1: a run carrying no conf flag leaves the conf byte-identical"

echo "--- case H1: relative path flags are made absolute before anything reads them ---"

CH1=$(mkcfg); WD="$TMP/h1wd"; mkdir -p "$WD"
out=$(inst_at "$WD" "$CH1" --bindir relbin --data-dir reldata --primary-cfg relcfg)
rc=$?
report 0 "$rc" "case H1: exit 0"
report "$WD/reldata" "$(conf_value "$CH1/session.conf" SESSION_DATA_DIR)" \
    "case H1: --data-dir is recorded absolute"
report "$WD/relcfg" "$(conf_value "$CH1/session.conf" SESSION_PRIMARY_CFG)" \
    "case H1: --primary-cfg is recorded absolute"
report yes "$(yesno test -d "$WD/reldata")" "case H1: the data root is created at the absolute path"
report "$SESSION_BIN" "$(readlink "$WD/relbin/session")" "case H1: --bindir is resolved against the cwd"
report no "$(yesno grep -q ':-rel' "$CH1/session.conf")" "case H1: no relative value survives into the conf"

echo "--- cases F5 and F13: flag values that would break or execute in session.conf ---"

for bad in '/tmp/us$age' '/tmp/gu"ard.sh' '/tmp/g`id`.sh'; do
    CB=$(mkcfg)
    out=$(inst "$CB" --bindir "$TMP/binbad" --data-dir "$bad"); rc=$?
    report 2 "$rc" "case F5: --data-dir '$bad' is a usage error"
    report absent "$([ -e "$CB/session.conf" ] && echo present || echo absent)" \
        "case F5: ... and nothing is written for it"
done
CB=$(mkcfg)
out=$(inst "$CB" --bindir "$TMP/binbad" --attend-grace 'ten minutes'); rc=$?
report 2 "$rc" "case F13: --attend-grace must be digits"
out=$(inst "$CB" --bindir "$TMP/binbad2" --attend-grace 900); rc=$?
report 0 "$rc" "case F13: ... and a number is fine"

echo "--- case F6: a written session.conf is proved readable and correct before ok ---"

# The fixture is a conf the installer CANNOT repair: a recorded line that is not
# valid shell, kept verbatim by the merge rule (case F1) and carried into the
# file this run writes, so `. "$conf"` fails where every producer's will. The
# unreadable-mode fixture this case used to carry moved to the conf-trust case,
# which is now a repair rather than a refusal — that half no longer proves the read-back.
CF6=$(mkcfg); DF6="$TMP/dataf6"; GF6="$TMP/guardf6.sh"; : > "$GF6"
printf 'SESSION_DATA_DIR="${SESSION_DATA_DIR:-/x\n' > "$CF6/session.conf"
out=$(inst "$CF6" --bindir "$TMP/binf6" --main-guard "$GF6"); rc=$?
report 1 "$rc" "case F6: a conf that cannot be read back is a refusal, not an ok"
report yes "$(yesno grep -q 'REFUSE' <<<"$out")" "case F6: ... reported as one"
report no "$(yesno grep -qE '^ok .*session\.conf' <<<"$out")" "case F6: ... and never as ok"
# Control: the same run against a well-formed recorded line reports ok.
printf 'SESSION_DATA_DIR="${SESSION_DATA_DIR:-%s}"\n' "$DF6" > "$CF6/session.conf"
out=$(inst "$CF6" --bindir "$TMP/binf6" --main-guard "$GF6"); rc=$?
report 0 "$rc" "case F6: ... while a readable one is an ok (the control)"
report yes "$(yesno grep -qE '^ok .*session\.conf' <<<"$out")" "case F6: ... reported as one"

echo "--- conf trust: the conf reported ok is one the lib will actually read ---"

# `>` preserves the mode of a conf that already existed, and the lib skips a conf
# that is group- or world-writable: the install reported ok, the lib ignored it,
# and every producer resolved the DEFAULT root while producer and consumer agreed
# on the wrong directory. Sourced here the way a producer does, not by hand.
lib_data_root() {  # CFGDIR -> the data root a producer sourcing the lib resolves
    env -i PATH="$IPATH" HOME="$IHOME" CLAUDE_CONFIG_DIR="$1" \
        bash -c '. "$0"; printf "%s\n" "$SESSION_DATA"' "$CLONE/lib/common.sh" 2>/dev/null
}

CW1=$(mkcfg); BW1="$TMP/binw1"; DW1="$TMP/dataw1"
printf 'SESSION_DATA_DIR="${SESSION_DATA_DIR:-/somewhere/old}"\n' > "$CW1/session.conf"
chmod 664 "$CW1/session.conf"
out=$(inst "$CW1" --bindir "$BW1" --data-dir "$DW1"); rc=$?
report 0 "$rc" "conf trust: a pre-existing group-writable conf does not refuse the run"
report 600 "$(mode_of "$CW1/session.conf")" "conf trust: ... its mode is repaired to 600"
report "$DW1" "$(lib_data_root "$CW1")" \
    "conf trust: ... so a producer sourcing the lib resolves the recorded root, not the default"
report no "$(yesno grep -qE '^  FAIL +session.conf' <<<"$out")" \
    "conf trust: ... and the doctor the run ends with does not reject what the run just wrote"

# The control: a fresh conf was already 600, from the lib's umask.
report 600 "$(mode_of "$C26b/session.conf")" "conf trust: a freshly written conf is 600 (the control)"

echo "--- cases F2 and M3: uninstall removes ours by path, and only the written shape otherwise ---"

# A clone whose directory is not named `session` — the shape the ownership regex
# cannot see, and which install.sh deliberately does not depend on.
ODIR="$TMP/oddclone/sess"
mkclone "$ODIR"
CM3=$(mkcfg); BM3="$TMP/binm3"
out=$(env -i PATH="$IPATH" HOME="$IHOME" FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
      CLAUDE_CONFIG_DIR="$CM3" bash "$ODIR/install.sh" --bindir "$BM3" 2>&1)
report 8 "$(jq '[.hooks[]?[]?.hooks[]? | select(.command|test("--hook|--turn-|--session-end|--subagent-|--compact-mark|--perm-mark"))] | length' "$CM3/settings.json")" \
    "case M3: a clone not named session installs eight entries"
out=$(env -i PATH="$IPATH" HOME="$IHOME" CLAUDE_CONFIG_DIR="$CM3" \
      bash "$ODIR/uninstall.sh" --bindir "$BM3" 2>&1); rc=$?
report 0 "$rc" "case M3: uninstall exits 0"
report 0 "$(jq '[.hooks[]?[]?.hooks[]?] | length' "$CM3/settings.json")" \
    "case M3: ... and removes them all (path equality, not the directory's name)"

# Foreign commands that merely mention the ownership strings.
CM3b=$(mkcfg); BM3b="$TMP/binm3b"
out=$(inst "$CM3b" --bindir "$BM3b")
jq '.hooks.Stop += [{"hooks":[
      {"type":"command","command":"/opt/othertool/bin/session/session --lint"},
      {"type":"command","command":"echo my-rewake-waiter-notes.txt"},
      {"type":"command","command":"grep -r \"/session/session --\" /srv/audit"}]}]' \
   "$CM3b/settings.json" > "$TMP/t.m3b" && mv "$TMP/t.m3b" "$CM3b/settings.json"
out=$(uninst "$CM3b" --bindir "$BM3b")
report 3 "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command|test("othertool|my-rewake-waiter-notes|srv/audit"))] | length' "$CM3b/settings.json")" \
    "case M3: three commands that only mention the ownership strings all survive"
# Not the LIFECYCLE probe here: two of the three foreign fixtures deliberately
# contain the ownership string, so the crude regex counts them. Ask the question
# that matters instead — is anything still pointing at this clone.
report 0 "$(jq --arg b "$SESSION_BIN" '[.hooks[]?[]?.hooks[]? | select(.command|test($b; "x"))] | length' "$CM3b/settings.json")" \
    "case M3: nothing pointing at this clone survives"

# Nothing of ours: a skip, not an ok claiming a removal.
CM3c=$(mkcfg)
printf '{"model":"opus"}\n' > "$CM3c/settings.json"
out=$(uninst "$CM3c" --bindir "$TMP/binm3c"); rc=$?
report 0 "$rc" "case F2: uninstall with nothing of ours exits 0"
report no "$(yesno grep -qE '^ok .*removed 0' <<<"$out")" "case F2: ... and never reports removing 0 entries as ok"

echo "--- tilde form: the other-clone shape, tilde form included, in both scripts ---"

# install.sh matched `bash ~/…/session/session --…` and uninstall.sh did not, so
# another clone's entries written in the tilde form (the shape a hand-deployed
# settings file may use) survived an uninstall. $HOME is the suite's fake home, which is what
# _entry_path expands `~` to — against the real one these paths read as dead and
# the gap looks fixed.
TILDE="$IHOME/tildeclone/session"
mkclone "$TILDE"
CW4=$(mkcfg); BW4="$TMP/binw4"
out=$(inst "$CW4" --bindir "$BW4")
jq '.hooks.Stop += [{"hooks":[
      {"type":"command","command":"bash ~/tildeclone/session/session --turn-end || true","timeout":2},
      {"type":"command","command":"bash ~/tildeclone/session/session --rewake-waiter","timeout":700000}]}]' \
   "$CW4/settings.json" > "$TMP/t.w4" && mv "$TMP/t.w4" "$CW4/settings.json"
report 2 "$(jq '[.hooks[]?[]?.hooks[]? | select(.command|test("tildeclone"))] | length' "$CW4/settings.json")" \
    "tilde form: (fixture) two live entries of another clone, written with a tilde"
out=$(uninst "$CW4" --bindir "$BW4"); rc=$?
report 0 "$rc" "tilde form: uninstall exits 0"
report 0 "$(jq '[.hooks[]?[]?.hooks[]? | select(.command|test("tildeclone"))] | length' "$CW4/settings.json")" \
    "tilde form: ... and removes both, the lifecycle one and the rewake one"

CW4b=$(mkcfg); BW4b="$TMP/binw4b"
cat > "$CW4b/settings.json" <<TILDEEOF
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"bash ~/tilde-gone/session/session --turn-end || true","timeout":2}]}]}}
TILDEEOF
out=$(inst "$CW4b" --bindir "$BW4b")
report 0 "$(jq '[.hooks.Stop[].hooks[]|select(.command|test("tilde-gone"))]|length' "$CW4b/settings.json")" \
    "tilde form: install drops a DEAD entry in the tilde form (the shape both scripts now share)"

# A copy of this CLI deployed under some other config directory is nobody's
# install: neither script treats its entries as ours.
CW4c=$(mkcfg); BW4c="$TMP/binw4c"
HOSTCOPY="$TMP/livehost/claude/scripts/session.sh"
mkdir -p "$(dirname "$HOSTCOPY")"; printf '#!/bin/sh\n' > "$HOSTCOPY"; chmod +x "$HOSTCOPY"
out=$(inst "$CW4c" --bindir "$BW4c")
jq --arg c "$HOSTCOPY --turn-end" '.hooks.Stop += [{"hooks":[{"type":"command","command":$c,"timeout":2}]}]' \
   "$CW4c/settings.json" > "$TMP/t.w4c" && mv "$TMP/t.w4c" "$CW4c/settings.json"
out=$(uninst "$CW4c" --bindir "$BW4c")
report 1 "$(jq --arg c "$HOSTCOPY --turn-end" '[.hooks[]?[]?.hooks[]?|select(.command==$c)]|length' "$CW4c/settings.json")" \
    "tilde form: a live entry of a deployed copy is left alone by uninstall"

echo "--- case M2: a refused rewake gate leaves working entries armed ---"

CM2=$(mkcfg); BM2="$TMP/binm2"
out=$(inst "$CM2" --bindir "$BM2")
report 2 "$(jq "$REWAKE | length" "$CM2/settings.json")" "case M2: armed by the first run"
FAKE_CLAUDE_VERSION=2.1.99
out=$(inst "$CM2" --bindir "$BM2"); rc=$?
FAKE_CLAUDE_VERSION=2.1.251
report 1 "$rc" "case M2: the re-run refuses the gate"
report 2 "$(jq "$REWAKE | length" "$CM2/settings.json")" \
    "case M2: ... and the two working entries are still armed"
report 8 "$(jq "$LIFECYCLE | length" "$CM2/settings.json")" "case M2: ... beside the eight lifecycle entries"
out=$(inst "$CM2" --bindir "$BM2" --no-rewake); rc=$?
report 0 "$rc" "case M2: an explicit --no-rewake exits 0"
report 0 "$(jq "$REWAKE | length" "$CM2/settings.json")" "case M2: ... and does disarm them"

echo "--- cases F7 and M4: a space in a clone path breaks nothing ---"

# Another clone's LIVE entry, at a path with a space, must survive an install
# from an unrelated clone. The positive control is case 28 [stale], which pins
# the same thing at a space-free path.
SPACED="$TMP/other clone/session"
mkclone "$SPACED"
CM4=$(mkcfg); BM4="$TMP/binm4"
cat > "$CM4/settings.json" <<SPACEEOF
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"bash $SPACED/session --turn-end || true","timeout":2}]}]}}
SPACEEOF
out=$(inst "$CM4" --bindir "$BM4")
report 1 "$(jq --arg c "bash $SPACED/session --turn-end || true" \
    '[.hooks.Stop[].hooks[]|select(.command==$c)]|length' "$CM4/settings.json")" \
    "case M4: a live entry of another clone at a path with a space survives"

# And an install FROM a path with a space is idempotent and knows its own
# statusLine.
CM4b=$(mkcfg); BM4b="$TMP/binm4b"
out=$(env -i PATH="$IPATH" HOME="$IHOME" FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
      CLAUDE_CONFIG_DIR="$CM4b" bash "$SPACED/install.sh" --bindir "$BM4b" 2>&1); rc=$?
report 0 "$rc" "case M4: installing from a path with a space exits 0"
cp "$CM4b/settings.json" "$TMP/before-m4b"
out=$(env -i PATH="$IPATH" HOME="$IHOME" FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
      CLAUDE_CONFIG_DIR="$CM4b" bash "$SPACED/install.sh" --bindir "$BM4b" 2>&1); rc=$?
report 0 "$rc" "case M4: the second run does not refuse its own statusLine"
report yes "$(yesno cmp -s "$TMP/before-m4b" "$CM4b/settings.json")" "case M4: ... and is a byte-identical no-op"

# Dropped entries are named, not silently removed.
CM4c=$(mkcfg); BM4c="$TMP/binm4c"
cat > "$CM4c/settings.json" <<GONEEOF
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"bash $TMP/vanished/session/session --turn-end || true","timeout":2}]}]}}
GONEEOF
out=$(inst "$CM4c" --bindir "$BM4c")
report yes "$(yesno grep -q "$TMP/vanished/session/session" <<<"$out")" \
    "case F7: a dropped stale entry is named in the report"

# The dead-path rule fires on the shape this CLI is written as, not on any command
# whose script is missing: a deployed copy under a config directory and a foreign
# tool both stay, dead or not.
CM4d=$(mkcfg); BM4d="$TMP/binm4d"
cat > "$CM4d/settings.json" <<SHAPEEOF
{"hooks":{"Stop":[{"hooks":[
  {"type":"command","command":"$TMP/gonehost/claude/scripts/session.sh --turn-end","timeout":2},
  {"type":"command","command":"$TMP/gonetool/bin/session.sh --run","timeout":2}]}]}}
SHAPEEOF
out=$(inst "$CM4d" --bindir "$BM4d")
report 1 "$(jq --arg c "$TMP/gonehost/claude/scripts/session.sh --turn-end" \
    '[.hooks.Stop[].hooks[]|select(.command==$c)]|length' "$CM4d/settings.json")" \
    "case F7: a deployed copy's dead entry is not ours to delete"
report 1 "$(jq --arg c "$TMP/gonetool/bin/session.sh --run" \
    '[.hooks.Stop[].hooks[]|select(.command==$c)]|length' "$CM4d/settings.json")" \
    "case F7: a foreign tool's dead entry is not ours to delete"

echo "--- case F3: the armed line only where something was armed ---"

CF3=$(mkcfg); BF3="$TMP/binf3"
out=$(inst "$CF3" --bindir "$BF3" --dry-run)
report no "$(yesno grep -qE '^ok .*auto-resume: armed' <<<"$out")" "case F3: a dry run never says armed"
report yes "$(yesno grep -q 'would arm' <<<"$out")" "case F3: ... it says it would arm"

if perms_bite; then
    CF3b=$(mkcfg); BF3b="$TMP/binf3b"
    printf '{"foo":1}\n' > "$CF3b/settings.json"; chmod 500 "$CF3b"
    out=$(inst "$CF3b" --bindir "$BF3b"); rc=$?
    chmod 700 "$CF3b"
    report 1 "$rc" "case F3: an unwritable config dir refuses"
    report no "$(yesno grep -qE '^ok .*auto-resume: armed' <<<"$out")" \
        "case F3: ... and nothing claims the waiter was armed"
else
    skip "case F3: an unwritable config dir" "$ROOT_SKIP"
fi

echo "--- case F4: a symlinked settings.json is edited through, not replaced ---"

CF4=$(mkcfg); BF4="$TMP/binf4"; DOT="$TMP/dotfiles"; mkdir -p "$DOT"
printf '{"model":"opus"}\n' > "$DOT/settings.json"
ln -sfn "$DOT/settings.json" "$CF4/settings.json"
out=$(inst "$CF4" --bindir "$BF4"); rc=$?
report 0 "$rc" "case F4: exit 0"
report yes "$(yesno test -L "$CF4/settings.json")" "case F4: the symlink is still a symlink"
report 8 "$(jq "$LIFECYCLE | length" "$DOT/settings.json")" "case F4: the dotfiles target received the entries"
report "opus" "$(jq -r '.model' "$DOT/settings.json")" "case F4: ... keeping what it had"
report yes "$(yesno test -f "$DOT/settings.json.session-bak")" "case F4: the backup lands beside the target"

echo "--- case F8: a settings.json that changed under us is refused, not clobbered ---"

CF8=$(mkcfg); BF8="$TMP/binf8"
printf '{"model":"opus"}\n' > "$CF8/settings.json"
CASBIN="$TMP/casbin"; mkdir -p "$CASBIN"
cat > "$CASBIN/jq" <<'CASEOF'
#!/bin/sh
# Rewrites the target once, at the moment the merge is computed — the window
# between the installer's read and its write.
prev=""; inject=0
for a in "$@"; do
    [ "$prev" = "--argjson" ] && [ "$a" = "spec" ] && inject=1
    prev="$a"
done
if [ "$inject" = 1 ] && [ -n "${CAS_TARGET:-}" ] && [ ! -e "$CAS_TARGET.injected" ]; then
    "$REAL_JQ" '. + {"concurrent":"writer"}' "$CAS_TARGET" > "$CAS_TARGET.new" \
        && mv "$CAS_TARGET.new" "$CAS_TARGET"
    : > "$CAS_TARGET.injected"
fi
exec "$REAL_JQ" "$@"
CASEOF
chmod +x "$CASBIN/jq"
out=$(env -i PATH="$CASBIN:$IPATH" HOME="$IHOME" FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
      REAL_JQ="$(command -v jq)" CAS_TARGET="$CF8/settings.json" \
      CLAUDE_CONFIG_DIR="$CF8" bash "$INSTALL" --bindir "$BF8" 2>&1); rc=$?
report 1 "$rc" "case F8: a concurrent write is refused"
report yes "$(yesno grep -q 'REFUSE' <<<"$out")" "case F8: ... with a refusal"
report "writer" "$(jq -r '.concurrent' "$CF8/settings.json")" "case F8: ... and the other writer's key survives"

echo "--- case F9: a non-object statusLine is foreign ---"

CF9=$(mkcfg); BF9="$TMP/binf9"
printf '{"statusLine":"bash /opt/mytool/prompt.sh"}\n' > "$CF9/settings.json"
out=$(inst "$CF9" --bindir "$BF9"); rc=$?
report 1 "$rc" "case F9: exit 1"
report yes "$(yesno grep -q 'REFUSE' <<<"$out")" "case F9: a refusal"
report "bash /opt/mytool/prompt.sh" "$(jq -r '.statusLine' "$CF9/settings.json")" \
    "case F9: the string statusLine is left exactly as it was"
report 8 "$(jq "$LIFECYCLE | length" "$CF9/settings.json")" "case F9: the hook entries still landed"

echo "--- case F10: the data root's ok depends on the .gitignore actually being there ---"

CF10=$(mkcfg); DF10="$TMP/dataf10"
mkdir -p "$DF10/.gitignore"          # a directory: the deterministic way to fail the write
out=$(inst "$CF10" --bindir "$TMP/binf10" --data-dir "$DF10"); rc=$?
report 1 "$rc" "case F10: a .gitignore that cannot be written is a refusal"
report no "$(yesno grep -qE '^ok .*data root.*gitignore' <<<"$out")" \
    "case F10: ... and the data root never reports ok for it"

echo "--- case F11: a failed backup never destroys the previous one ---"

CF11=$(mkcfg); BF11="$TMP/binf11"
out=$(inst "$CF11" --bindir "$BF11")
printf '{"model":"opus"}\n' > "$CF11/settings.json"
cp "$CF11/settings.json" "$TMP/f11-live"
chmod 000 "$CF11/settings.json.session-bak"
out=$(inst "$CF11" --bindir "$BF11"); rc=$?
chmod 600 "$CF11/settings.json.session-bak" 2>/dev/null
report 0 "$rc" "case F11: an unwritable backup path does not stop the install"
report "opus" "$(jq -r '.model' "$TMP/f11-live")" "case F11: (control) the live file before the run"
report "opus" "$(jq -r '.model' "$CF11/settings.json.session-bak")" \
    "case F11: the backup holds the pre-run content, not an empty file"
report absent "$(ls "$CF11"/*.session-bak.tmp >/dev/null 2>&1 && echo present || echo absent)" \
    "case F11: no backup tmp file is left behind"

echo "--- case F12: a statusLine of ours whose file is gone is repaired ---"

GONECLONE="$TMP/goneclone/session"
mkclone "$GONECLONE"
CF12=$(mkcfg); BF12="$TMP/binf12"
out=$(env -i PATH="$IPATH" HOME="$IHOME" FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
      CLAUDE_CONFIG_DIR="$CF12" bash "$GONECLONE/install.sh" --bindir "$BF12" 2>&1)
rm -rf "$TMP/goneclone"
out=$(inst "$CF12" --bindir "$BF12"); rc=$?
report 0 "$rc" "case F12: a dead statusLine of this shape is not a permanent refusal"
report "bash $STATUSLINE" "$(jq -r '.statusLine.command' "$CF12/settings.json")" \
    "case F12: ... it is replaced with ours"
report yes "$(yesno grep -q 'no longer exists' <<<"$out")" "case F12: ... and the replacement is stated"
# The third pointer the installer owns has the same dead-target case: a symlink
# into a clone that was deleted names nothing, and refusing it would make every
# later install fail over a dead name.
report "$SESSION_BIN" "$(readlink "$BF12/session")" "case F12: a dangling symlink into a deleted clone is repointed"
DANGLE="$TMP/bin-dangle"; mkdir -p "$DANGLE"
ln -sfn "$TMP/no-such-tool/bin/thing" "$DANGLE/session"
CF12b=$(mkcfg)
out=$(inst "$CF12b" --bindir "$DANGLE"); rc=$?
report 1 "$rc" "case F12: a dangling symlink to something else still refuses"
report "$TMP/no-such-tool/bin/thing" "$(readlink "$DANGLE/session")" "case F12: ... and is left alone"

echo "--- case L4: neither script edits a group it has no business in ---"

CL4=$(mkcfg); BL4="$TMP/binl4"
printf '{"hooks":{"PreToolUse":[{"matcher":"Bash"}]},"model":"opus"}\n' > "$CL4/settings.json"
out=$(inst "$CL4" --bindir "$BL4")
report "null" "$(jq -r '.hooks.PreToolUse[0].hooks // "null"' "$CL4/settings.json")" \
    "case L4: install does not give a foreign group an empty hooks array"
out=$(uninst "$CL4" --bindir "$BL4")
report 1 "$(jq '.hooks.PreToolUse | length' "$CL4/settings.json")" \
    "case L4: uninstall keeps a group it did not empty"
report "opus" "$(jq -r '.model' "$CL4/settings.json")" "case L4: ... and everything else"

echo "--- case L5: uninstall's summary states only what happened ---"

CL5=$(mkcfg); BL5="$TMP/binl5"
out=$(inst "$CL5" --bindir "$BL5" --no-rewake)
out=$(uninst "$CL5" --bindir "$BL5")
report no "$(yesno grep -q '  and ' <<<"$out")" "case L5: no doubled space in the summary"

echo "--- uninstall: a second wiring of the same clone survives (the PATH sweep is a fallback) ---"

# Two installs can share one clone (a teammate simulation beside a production
# install did, 2026-08-31, and the sim's uninstall reaped the production link).
# With --bindir given and that link ours, the PATH-resolved twin is not this
# install's to remove; with nothing at --bindir, the sweep is the fallback that
# still finds a forgotten install.
CU2=$(mkcfg); BU2a="$TMP/binu2a"; BU2b="$TMP/binu2b"; mkdir -p "$BU2a" "$BU2b"
inst "$CU2" --bindir "$BU2a" >/dev/null
ln -s "$SESSION_BIN" "$BU2b/session"     # the "production" twin
OLDIPATH="$IPATH"; IPATH="$BU2b:$IPATH"
uninst "$CU2" --bindir "$BU2a" >/dev/null; rc=$?
report 0 "$rc" "uninstall [twin]: exit 0"
report no "$(yesno test -e "$BU2a/session")" "uninstall [twin]: the named bindir link is removed"
report yes "$(yesno test -L "$BU2b/session")" "uninstall [twin]: the PATH twin of the same clone survives"
uninst "$CU2" --bindir "$TMP/nonexistent-bindir" >/dev/null
report no "$(yesno test -L "$BU2b/session")" "uninstall [twin]: with nothing at --bindir, the sweep still finds a forgotten install"
IPATH="$OLDIPATH"

echo "--- case L7: an unreadable settings.json is diagnosed as unreadable ---"

if perms_bite; then
    CL7=$(mkcfg); BL7="$TMP/binl7"
    printf '{"model":"opus"}\n' > "$CL7/settings.json"; chmod 000 "$CL7/settings.json"
    out=$(inst "$CL7" --bindir "$BL7"); rc=$?
    chmod 600 "$CL7/settings.json"
    report 1 "$rc" "case L7: exit 1"
    report no "$(yesno grep -q 'not valid JSON' <<<"$out")" "case L7: not diagnosed as invalid JSON"
    report yes "$(yesno grep -qi 'cannot be read' <<<"$out")" "case L7: diagnosed as unreadable"
else
    skip "case L7: an unreadable settings.json" "$ROOT_SKIP"
fi

echo "--- case L8: no ok for a link that was not made ---"

if perms_bite; then
    CL8=$(mkcfg); BL8="$TMP/binl8"; mkdir -p "$BL8"
    printf '#!/bin/sh\n' > "$BL8/session"; chmod +x "$BL8/session"
    chmod 500 "$BL8"
    out=$(inst "$CL8" --bindir "$BL8" --force-link); rc=$?
    chmod 700 "$BL8"
    report 1 "$rc" "case L8: a link that cannot be made refuses"
    report no "$(yesno grep -qE '^ok      CLI:' <<<"$out")" "case L8: ... and prints no ok for it"
else
    skip "case L8: a link that cannot be made" "$ROOT_SKIP"
fi

echo "--- case L2-2: the scripts refuse loudly when reached through a symlink ---"

CT2=$(mkcfg); LNK="$TMP/install-link.sh"
ln -sfn "$INSTALL" "$LNK"
out=$(env -i PATH="$IPATH" HOME="$IHOME" FAKE_CLAUDE_VERSION="$FAKE_CLAUDE_VERSION" \
      CLAUDE_CONFIG_DIR="$CT2" bash "$LNK" --bindir "$TMP/bint2" 2>&1); rc=$?
report 1 "$rc" "case L2-2: install.sh reached through a symlink refuses"
report yes "$(yesno grep -qi 'symlink\|directly' <<<"$out")" "case L2-2: ... saying why"

echo "--- uninstall's half-installed and refusal branches ---"

# statusLine only
CU1=$(mkcfg); BU1="$TMP/binu1"
out=$(inst "$CU1" --bindir "$BU1")
jq 'del(.hooks)' "$CU1/settings.json" > "$TMP/t.u1" && mv "$TMP/t.u1" "$CU1/settings.json"
out=$(uninst "$CU1" --bindir "$BU1"); rc=$?
report 0 "$rc" "case U: a statusLine-only install uninstalls cleanly"
report "null" "$(jq -r '.statusLine // "null"' "$CU1/settings.json")" "case U: ... the statusLine is gone"

# hooks only
CU2=$(mkcfg); BU2="$TMP/binu2"
out=$(inst "$CU2" --bindir "$BU2")
jq 'del(.statusLine)' "$CU2/settings.json" > "$TMP/t.u2" && mv "$TMP/t.u2" "$CU2/settings.json"
out=$(uninst "$CU2" --bindir "$BU2"); rc=$?
report 0 "$rc" "case U: a hooks-only install uninstalls cleanly"
report 0 "$(jq '[.hooks[]?[]?.hooks[]?] | length' "$CU2/settings.json")" "case U: ... the entries are gone"

# invalid JSON
CU3=$(mkcfg); printf 'not json\n' > "$CU3/settings.json"
out=$(uninst "$CU3" --bindir "$TMP/binu3"); rc=$?
report 1 "$rc" "case U: uninstall refuses an unparsable settings.json"
report "not json" "$(cat "$CU3/settings.json")" "case U: ... leaving it exactly as it was"

if perms_bite; then
    # unwritable config dir
    CU4=$(mkcfg); BU4="$TMP/binu4"
    out=$(inst "$CU4" --bindir "$BU4")
    chmod 500 "$CU4"
    out=$(uninst "$CU4" --bindir "$BU4"); rc=$?
    chmod 700 "$CU4"
    report 1 "$rc" "case U: uninstall refuses when it cannot write"
    report 8 "$(jq "$LIFECYCLE | length" "$CU4/settings.json")" "case U: ... and changes nothing"
else
    skip "case U: uninstall cannot write" "$ROOT_SKIP"
fi

# a dangling symlink at the name
CU5=$(mkcfg); BU5="$TMP/binu5"; mkdir -p "$BU5"
out=$(inst "$CU5" --bindir "$BU5")
GONELINK="$TMP/gonecli/session"; mkdir -p "$TMP/gonecli"; : > "$GONELINK"
ln -sfn "$GONELINK" "$BU5/other"; rm -f "$GONELINK"
out=$(uninst "$CU5" --bindir "$BU5" --name other); rc=$?
report 0 "$rc" "case U: a dangling symlink at the name is not ours and does not crash"
report yes "$(yesno test -L "$BU5/other")" "case U: ... it is left alone"

# no jq
CU6=$(mkcfg); BU6="$TMP/binu6"
out=$(inst "$CU6" --bindir "$BU6")
NOJQ="$TMP/nojqbin"; mkdir -p "$NOJQ"
for t in bash sh sed ls cat id mkdir chmod ln rm mv cp diff dirname basename tr awk stat; do
    tp=$(command -v "$t") && ln -sf "$tp" "$NOJQ/$t"
done
if env -i PATH="$NOJQ" sh -c 'command -v jq' >/dev/null 2>&1; then
    skip "case U [no jq]" "jq is still on the minimal PATH"
else
    out=$(env -i PATH="$NOJQ" HOME="$IHOME" CLAUDE_CONFIG_DIR="$CU6" \
          bash "$UNINSTALL" --bindir "$BU6" 2>&1); rc=$?
    report 1 "$rc" "case U: uninstall without jq refuses"
    report 8 "$(jq "$LIFECYCLE | length" "$CU6/settings.json")" "case U: ... and changes no settings"
fi

echo "--- warn-thr: a hand-set USAGE_WARN_PCT survives a re-run that rewrites the conf ---"

# No flag writes this one — it is the only knob whose home is a hand-edited line
# — so the merge rule has to keep it, or the next re-run carrying any flag
# silently restores the default threshold on a machine that chose another.
CWT=$(mkcfg); BWT="$TMP/binwt"; DWT="$TMP/datawt"
out=$(inst "$CWT" --bindir "$BWT" --data-dir "$DWT")
printf 'USAGE_WARN_PCT="${USAGE_WARN_PCT:-85}"\n' >> "$CWT/session.conf"
out=$(inst "$CWT" --bindir "$BWT" --attend-grace 900); rc=$?
report 0 "$rc" "warn-thr: a re-run carrying another flag exits 0"
report "85" "$(conf_value "$CWT/session.conf" USAGE_WARN_PCT)" \
    "warn-thr: ... and the hand-set threshold is still there"
report 1 "$(grep -c '^USAGE_WARN_PCT=' "$CWT/session.conf")" \
    "warn-thr: ... exactly once"

echo "--- hand-set knobs: the switcher's two lines survive a re-run as well ---"

# The switcher's rollback is one hand-appended line, in the plain form the
# README gives, so a re-run carrying any flag must not silently re-arm it.
printf 'SESSION_AUTO_SWITCH=off\n' >> "$CWT/session.conf"
printf 'SESSION_SWITCH_NOTIFY="${SESSION_SWITCH_NOTIFY:-/tmp/notify-wt.sh}"\n' >> "$CWT/session.conf"
out=$(inst "$CWT" --bindir "$BWT" --attend-grace 600); rc=$?
report 0 "$rc" "hand-set knobs: a re-run carrying another flag exits 0"
report "off" "$(conf_value "$CWT/session.conf" SESSION_AUTO_SWITCH)" \
    "hand-set knobs: ... and a switcher turned off stays off"
report "/tmp/notify-wt.sh" "$(conf_value "$CWT/session.conf" SESSION_SWITCH_NOTIFY)" \
    "hand-set knobs: ... with its notify target still recorded"

report "$SHIPPED_BEFORE" "$(shipped_sums)" "the suite modified none of the shipped files in the checkout"

echo
echo "$pass passed, $fail failed, $skipped skipped"
[ "$fail" -eq 0 ]
