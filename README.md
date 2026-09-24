# session

`session` tells a Claude Code session, or you, which session it is, how much of the subscription's shared 5-hour and weekly rate limits it has used and when they reset, and how much time went into it. It also paces multi-agent jobs against those limits, switches between several subscription logins in place (by hand, or by itself when a cap hits), wakes a session that a usage cap paused, and reopens every session after a reboot. It is one bash script plus a Claude Code statusline that feeds it, wired into your Claude Code configuration from a git clone by `install.sh`.

```
$ session
── session overview ───────────────────────────────
  id       a1000000-0000-0000-0000-000000000000
  name     Link session ID to usage tracking tool
  account  you@example.com
  5-hour   █░░░░░░░░░  13%   resets to 0% in 1h33m    (pace cap 69%)
  weekly   █████░░░░░  54%   resets to 0% in 5d17h    (pace cap 18%)
  context  ███░░░░░░░  31%   (this session)
  share    ≈3.1% of 5h · ≈1.0% of wk   ($13.30 this 5h window; `session usage --all`)
──────────────────────────────────────────────────
  Fable 5 · cache 2s old
```

Time is measured per turn from Claude Code's hooks, so the idle gaps between turns never count and headless `claude -p` runs are counted like any other. `session time --json` is a stable contract a task logger can book time against ([below](#time---json--the-contract-a-task-logger-reads)), and `session doctor` checks that an install really produces it.

`session --help` is the flag reference and every verb takes `-h`. This file covers installing, what each figure means and how it is made, what is stored on disk, and what is true only on Linux.

## Install

**Requirements:** bash and `jq` (the installer refuses without `jq`); `tmux` too if you want attended time and the reboot/resume features.

**1. Clone the repository** somewhere under your own home; the clone's path is what every hook entry will carry.

```
git clone <this repository> ~/code/session
```

**2. Run the installer from the clone**, with the flags that describe this machine (`install.sh --help` lists them all):

```
~/code/session/install.sh --bindir ~/bin --data-dir ~/.local/share/session
```

Pass `--bindir DIR` when `~/.local/bin` is not on your `PATH` (the installer prints the `export PATH` line when the directory it linked into is not). Pass `--data-dir DIR` when the usage store should live somewhere other than `<config dir>/session-usage`; on a machine that already has a store from an earlier install, point it there and nothing moves. Add `--primary-cfg PATH` when this machine's usual `CLAUDE_CONFIG_DIR` is not `~/.claude`, or every render will be tagged as a secondary login. `--main-guard`, `--attend-grace` and `--attend-tail` are rarely needed; the [Configuration](#configuration) table says what each moves. These flags are recorded in `<config dir>/session.conf`, so a later re-run without them keeps the values.

**3. Install the plugin for the skill.** The clone carries the code and the hook entries; the plugin carries only the `/session:session` skill that tells a session when to run it. Neither step implies the other.

```
claude plugin marketplace add <this repository>
claude plugin install session@session --scope user
```

**4. Restart Claude Code**, then send two prompts. Hooks and the `statusLine` load at session start, and a session's first render records nothing ([why](#verifying-an-install)). `session doctor` then reads `ok` or `pending` on every line; a `FAIL` names what is wired wrong.

Until the first turn has been logged, `session time --json` exits 1 with `session: no turn log yet at <path> (the per-turn hooks append it)`. A task logger should read that as "measurement was never on offer here", not as zero.

**Replacing an older copy of this CLI** on the same machine: point `--data-dir` at its existing store, remove its hook entries from `settings.json` yourself in the same edit (the installer leaves another copy's live entries alone, and two sets of hooks write two rows per turn into one store), and delete its files only once no running session still calls them.

### What the installer changes

The installer refuses to run from a Claude Code plugin cache (`plugins/cache/`) or from a directory you do not own. `settings.json` keeps the path it is given, and a plugin-cache path is replaced on every `claude plugin update`, which would leave every hook pointing at a directory that no longer exists; a plugin cannot set `statusLine` either. That is why the code comes from a clone and the plugin carries only the skill.

```
install.sh [--bindir DIR] [--name NAME] [--force-link] [--dry-run] [--no-rewake]
           [--data-dir DIR] [--main-guard PATH] [--attend-grace SECONDS]
           [--attend-tail SECONDS] [--primary-cfg PATH]
```

Every step prints `ok`, `skip` or `REFUSE <fact> <remedy>`. **A refusal never stops a later step** — a symlink name someone else already holds must not cost you the hook entries — and the exit status is 1 if any step refused. The `session doctor` run at the end is information: its status is deliberately not the installer's, so a fresh install that is correctly `pending` on five checks still exits 0.

What it writes into `$CLAUDE_CONFIG_DIR/settings.json`, all as absolute paths into the clone: eight lifecycle hook entries (`UserPromptSubmit --hook`, `Stop --turn-end`, `StopFailure --turn-fail`, `SessionEnd --session-end`, `SubagentStart --subagent-start`, `SubagentStop --subagent-end`, `PostCompact --compact-mark`, and `Notification --perm-mark` under `matcher: "permission_prompt"`), each `bash <clone>/session --<mode> || true` with `timeout: 2`; the two auto-resume entries; and the `statusLine`. Beside the settings file it creates the data root, links the CLI onto `PATH`, and — when any of the five conf-recorded flags is passed — writes `session.conf`. Only two top-level settings keys are ever added: `hooks` and `statusLine`.

**`|| true` on the lifecycle entries is load-bearing and its absence on the rewake pair is too.** A hook command is run through `/bin/sh` (dash on Debian and Ubuntu), so the shell metacharacters are interpreted and `|| true` is POSIX. The rewake pair must not carry it, because **exit 2 is the wake signal**: swallowing it leaves a waiter that sleeps out its whole wait and then wakes nobody.

**A re-run is a byte-identical no-op**. It identifies its own entries by the clone path inside the command rather than by a naming pattern, so an install from any directory layout replaces rather than duplicates. It additionally drops entries of this CLI's shape whose script no longer exists — a clone that was moved or deleted otherwise leaves hooks that fail on every turn — and leaves another clone's live entries alone.

**Refusals to expect**: a `statusLine` that is not ours is refused, not replaced, with the exact object to merge by hand printed beneath it; a symlink name already taken is refused unless you pass `--force-link` or `--name`; an unparsable `settings.json` refuses every settings step and is left untouched; an absent one is created as `{}`; and a `settings.json` that changed between the installer's read and its write is refused with the remedy to close Claude Code (which rewrites the file at runtime) and re-run. A `settings.json` that is a symlink — a dotfiles repo, say — is followed: the edit and its backup land at the target, and the link survives.

**`--dry-run` writes nothing at all** (no data root, symlink, `session.conf` or settings file): it prints the `jq -S` diff of the merge, against a virtual `{}` when there is no `settings.json`, and stops before the focus-tracking lines and `doctor`.

**Running Claude Code sessions are unaffected until they restart**, because hook configuration and the `statusLine` are read at session start.

On a shared machine, prefer a clone under your own home. The `statusLine` command is a path this configuration will run on every render; a clone in a world-writable location is a path another user could recreate.

### What each install state delivers

| State | What you get |
|---|---|
| Hook entries only (`statusLine` refused or declined) | `session time` and everything hook-fed: turn counts, active time, waits, subagent spans. No rate-limit figures at all — the 5h/weekly data exists only as statusline stdin, so `session`, `session usage`, `--guard` and `--wait` have no cache to read and exit 1. |
| Hook entries + `statusLine` | The overview, `usage`, `--guard`, `--wait`, `--compact`, `account`. `attended_s` falls back to active time and says so (`attended_basis: active`). |
| The above + the tmux/cron focus lines | Attended time as focused-tab time, idle-capped at `SESSION_ATTEND_GRACE`; `watched` (active ∩ attended); `attended_basis: focus`. |
| The above + the rewake pair (default) | A session paused by a usage cap wakes itself when the window resets or the login switches. With two or more vaulted logins, a cap or authentication death also reaches a decision about moving the box to one of them before the waiter sleeps. |

Nothing above is required by anything below it, and `session doctor` names which of them this machine currently has.

## Verifying an install

The full sequence, against scratch directories so nothing touches a real configuration:

```
export CLAUDE_CONFIG_DIR=$(mktemp -d)/claude; mkdir -p "$CLAUDE_CONFIG_DIR"
BINDIR=$(mktemp -d); PATH="$BINDIR:$PATH"

<clone>/install.sh --bindir "$BINDIR"
claude            # /login, then two prompts, then exit
session doctor    # every check ok or pending, nothing FAIL
session ; session usage
```

Everything here has been run except the interactive `claude` line, which needs a login. Without it `doctor` reads `pending` on the cache, the turn log, `time --json` and the switcher — the correct answer for a configuration nothing has run against yet, and the reason the next paragraph matters.

**Two prompts, not one.** A session's first render cannot tell whose rate-limit window it is looking at (a fresh session's first payload can still carry another login's), so it writes no cache; the second render does. After a single prompt `session` correctly reports no cache.

Then `uninstall.sh --bindir "$BINDIR"`, which should leave the scratch `settings.json` as `{}`.

## Commands

| Command | What it answers |
|---|---|
| `session` | the overview above: id, title, the 5-hour and weekly used % with reset countdowns, context fill, this session's share |
| `session whoami [--id\|--name\|--json]` | this session's id and title, correct across concurrent tmux panes |
| `session name <id-prefix>` · `session id <title-substring>` | another session's title from its id, or its id from its title |
| `session peers` | live sessions with the address `ListAgents` shows and `SendMessage` takes |
| `session usage [--all]` | counted `$` burn and estimated share of each window, for this session or every one ([how](#reading-the-figures)) |
| `session time [--all] [--yesterday \| --date D] [--json]` | turns, active, attended and watched time ([`--json`](#time---json--the-contract-a-task-logger-reads)) |
| `session --guard` · `session --wait guard` | pacing gate for multi-agent jobs: exit 0 go, 3 pause; the wait blocks until the guard would pass |
| `session account` · `session account use <row>` | saved logins with their headroom; switch the live login ([Accounts](#accounts), [automatic switching](#automatic-switching)) |
| `session reboot` · `session resume` | snapshot every live session and reboot; reopen them ([Reboot and resume](#reboot-and-resume)) |
| `session doctor` | check this install ([below](#session-doctor)) |

**active** is the sum of turn spans, tool time included and the gaps between turns left out. **attended** is time the session's tmux tab was focused, ending `SESSION_ATTEND_TAIL` seconds (by default the `SESSION_ATTEND_GRACE` bridge, 600) after the last keypress or scroll ([Focus tracking](#focus-tracking)). **watched** is their overlap.

## `session doctor`

Eleven checks, each asking whether the thing works *on this machine* and printing the fact it decided on. Four further lines appear only when they have something to report: `session.conf` when that file is broken or ignored, `warn pct` when `USAGE_WARN_PCT` is not a whole number, `credentials` when the live access token is empty, and `vault` when a vaulted entry holds the access token that is currently installed while filed under another login's name. Three states, because "not yet" and "wired wrong" have different remedies: **ok**, **pending** (nothing has produced it yet — usually "interact once"), **FAIL** (wired wrong, and the line says what). Only a FAIL exits 1.

1. **data root** — exists, writable, mode exactly 700, and the resolved path with where it can have come from: `from SESSION_DATA_DIR`, adding `which <conf> also sets` when the conf names it too (once the conf is sourced the two are indistinguishable), or the default.
2. **on PATH** — what `session` on `PATH` actually resolves to, FAIL when it is not this file. Two copies of this CLI on one machine is the failure mode the whole check exists for.
3. **settings** — `settings.json` parses, probed once before every check that reads it: FAIL when jq rejects it (everything downstream reads it as empty) or when it exists but cannot be read. Beside it, `session.conf` gets its own FAIL line when it is unreadable, skipped by the lib because this user does not own it or its mode is loose (the mode is printed either way), or not valid shell, and `warn pct` gets one when `USAGE_WARN_PCT` is not a whole number — a value that blocks *every* prompt with exit 2 on the synchronous hook entry and leaves the auto-resume waiter silently unarmed, and which only `doctor` still names, because `doctor` dispatches before the CLI validates it.
4. **cache** — present, parses, carries `rate_limits`, its age, and the Claude Code version it recorded. FAIL when it is over 120 s old inside a live session (the statusline is not rendering), and FAIL when it is absent while the root carries turn rows **and an effective statusLine of ours is configured for this directory** — hooks-only installs are a supported state and read `pending` here, with the note that the limit tiers stay unavailable.
5. **turn log** — FAIL on turn ends with no starts, the shape of a missing `UserPromptSubmit --hook` entry. A newest start days old is `ok`, with its age printed.
6. **time --json** — runs it and checks the contract a task logger reads, rather than reading the code that writes it.
7. **statusLine** — the **effective** one for the current directory, merging `$PWD/.claude/settings.local.json`, `$PWD/.claude/settings.json` and the config dir's `settings.json`, first hit wins. A project settings file in the directory a session runs from silently outranks yours (this also scopes check 4). Ownership is decided on the command's **last word**, resolved through symlinks, so a hand-written `statusLine` must keep the script path last, as the installer's `bash <abs>/statusline.sh` does.
8. **session id** — `whoami --id` is a UUID and equals `CLAUDE_CODE_SESSION_ID`.
9. **auto-resume** — the rewake entries, counted across every event. `ok` when every one carries `asyncRewake: true`, FAIL when some do not (those run synchronously and block the prompt) or when `settings.json` exists but cannot be read, `pending` when there are none.
10. **platform** — `perl`, `jq`, `tmux`, `inotifywait`, `flock(1)`, `/proc`, each present or absent with its fallback named. `perl` and `jq` missing is a FAIL; the rest are information. On Darwin it adds a `pending` line for `session account`.
11. **switcher** — whether a cap death here can move the box onto another vaulted login by itself. `ok` names the mode, the notify target, the vault's size beside how many of its entries carry an access token at all (a token that has since lapsed still counts — the probe is what calls it `lapsed`), the newest audit row with its event, and the newest cap death: a switcher that is triggered and records nothing reads as a gap between those last two. FAIL when `SESSION_AUTO_SWITCH` holds neither `on` nor `off`, when `SESSION_SWITCH_NOTIFY` names something that is not executable, or when no `--rewake-waiter` entry on **StopFailure** carries `asyncRewake: true` — the event a dying turn reaches, so an entry armed only on `UserPromptSubmit` leaves check 9 `ok` and the switcher with no trigger. `install.sh --no-rewake` arms neither entry: that install reads `pending` on check 9 and, once it has two vaulted logins, **FAIL** here, because the feature is on and nothing can carry a cap death to it. Recording `SESSION_AUTO_SWITCH=off` is what makes the two lines agree. `pending` for: off; no credentials file (a fresh install, or the macOS Keychain shape); fewer than two vaulted logins; no statusline cache for the live login (the rewake path exits without one, before any decision); no `curl` (decisions still run, on frozen figures). A second line follows when a decision left something to report: a `weekly_scoped` count above one, a usage response no window could be read from, or the decision lock not free.

A fresh install reads:

```
-- session doctor -------------------------------------------------
  code     <clone>
  ok       data root   <root> (mode 700, the default under the config dir)
  ok       on PATH     <bindir>/session
  ok       settings    <config dir>/settings.json parses
  pending  cache       no <root>/last-status.<login>.json yet — nothing has run against this root; interact once
  pending  turn log    no rows at <root>/turn-log.tsv yet — the lifecycle hooks append it
  pending  time --json no figures yet — nothing has written a turn log to report on
  ok       statusLine  <config dir>/settings.json
  ok       session id  a1000000-0000-0000-0000-000000000000
  ok       auto-resume 2 entr(y/ies), asyncRewake armed
  ok       platform    perl present · jq present · tmux present · inotifywait present · flock(1) · /proc
  pending  switcher    no <config dir>/.credentials.json — nothing has logged in here yet, or this Claude Code keeps credentials in the macOS Keychain, which this build cannot swap
-------------------------------------------------------------------
  nothing is wired wrong.
```

## Configuration

Everything is one environment variable with a default, declared once: the `SESSION_*` names in `lib/common.sh`, which every entry point sources, and the unprefixed knobs — `USAGE_WARN_PCT` below, and the `FIVE_GUARD`/`WEEK_GUARD`/`FIVE_WINDOW`/`WEEK_WINDOW` pace-guard specs — in `session`, their only consumer.

| Variable | Default | What it moves |
|---|---|---|
| `SESSION_DATA_DIR` | `<config dir>/session-usage` | the data root, and with it every log, cache, snapshot and archive |
| `SESSION_ACCOUNTS_DIR` | `<config dir>/accounts` | the credential vault |
| `SESSION_RESUME_QUEUE` | `<root>/resume-queue.tsv` | the reboot snapshot |
| `SESSION_ATTEND_GRACE` | `600` | the bridge: seconds of silence between two interactions still counted as one working stretch |
| `SESSION_ATTEND_TAIL` | the bridge's value | seconds of attention credited after the last interaction of a stretch |
| `SESSION_TMUX_MAIN_GUARD` | unset | a script `session resume` runs before it opens windows |
| `SESSION_AUTO_SWITCH` | `on` | whether a cap or authentication death may move the box to another vaulted login by itself. `on` or `off` and nothing else: any other value is refused rather than guessed at, and every decision refuses until it is corrected |
| `SESSION_SWITCH_NOTIFY` | unset | an executable run with one argument — the message — when the box switches login by itself, and when a save refuses a blank live credential. The same refusal met while switching is recorded and not sent. Empty sends nothing |
| `SESSION_PRIMARY_CFG` | `$HOME/.claude` | the config dir this machine treats as its primary login |
| `SESSION_NOW` | unset | a fixed "now" for the date layer; tests only |
| `USAGE_WARN_PCT` | `90` | the used % at or above which `session --hook` injects its usage line and ⚠ advisory, `session --rewake-waiter` arms, and a cached Fable figure counts as spent for the waiter's target; a whole number (anything else exits 2, except on `--rewake-waiter`, which exits 0 and arms nothing rather than turn a refusal into a wake-up), and above 100 turns the hook's output off entirely |

`SESSION_PRIMARY_CFG` is the one that is easy to get wrong. Every other config dir is a secondary login and is tagged as one (the ` · <cfgdir>` segment on the statusline, the `account` line on the overview), so on a machine whose usual `CLAUDE_CONFIG_DIR` is not `~/.claude` the default tags every render. Point it at that machine's own config dir.

**`session.conf`, at `<config dir>/session.conf`, is what reaches the contexts that inherit no shell environment**: tmux `run-shell`, cron, systemd units and Claude Code's own hooks. An export in a shell profile reaches none of them, so a machine whose data lives outside the default root needs the file rather than the variable. `install.sh` writes it from `--data-dir`, `--main-guard`, `--attend-grace`, `--attend-tail` and `--primary-cfg`, one line per flag passed, before it touches `settings.json` — so there is no window in which a producer this run wired resolves the default root. Recorded values survive every re-run — a variable this run's flags do not carry is re-emitted from the existing conf — but the file is rewritten whole, so hand-written comments in it do not; treat it as CLI-owned. No flag writes `SESSION_AUTO_SWITCH`, `SESSION_SWITCH_NOTIFY` or `USAGE_WARN_PCT` — add those lines by hand in the same `VAR="${VAR:-value}"` form, and a re-run re-emits them like any other recorded value, so a switcher turned off stays off. With none of the five passed and no conf on disk, none is created. The lib only trusts a conf **this user owns** and only this user can write: the installer writes it mode 600, and `session doctor` check 3 FAILs a conf the lib is skipping, printing its mode and the rule. Editing it with `sudo` is the way to break that quietly — the owner changes and the lib then skips the **whole file**, every recorded value with it, so a machine whose data lives outside the default root silently starts writing to the default one. Each line is written as `VAR="${VAR:-value}"`, so the environment still wins per variable and setting one never suppresses the others, and a value under the home directory is written as a literal `$HOME` so the file is portable and diffable. The lib reads it **before** filling in the `SESSION_DATA` default.

## The status line

One line: `<model> (<effort>) · <context> tkns, 5h: <pct> (<left>), wk: <pct> (<left>)`, then two segments that appear only when they have something to say: ` · <task>` and the ` · <cfgdir>` login tag above. The rate-limit pair is the login's newest *proven* windows, not whatever the payload happens to replay (the selection rules are in the script's comments); an expired window keeps its percentage and is marked `?`, never zeroed (the `seg:` cases in `tests/statusline.test.sh`).

**The task segment** names the task the session is working on, as an OSC 8 hyperlink marked `↗` when the task has a URL. It applies inside a *workspace*, the nearest ancestor of the session's working directory that contains `tasks/.sync/`. The task is the folder `tasks/<slug>/` containing the working directory or, failing that, the `slug` recorded for this session's id in `tasks/.sync/session-task.json` (a JSON object keyed by session id, which a task tool can write to point a session at a task). The title and link come from the folder's `identity.json` (`{"url": …, "title": …}`) or, when that is absent, from the first `# ` heading of its `task.md`, unlinked. A long title is cut to the part before `: `, ` — ` or ` - ` when that part has 12 or more characters, then to 40 characters at a word boundary. A missing folder or an unparsable file shows nothing.

**Under tmux, links are clickable only once the outer terminal is declared capable**: `set -sa terminal-features 'xterm*:hyperlinks'` for a terminal that renders them, such as VS Code's. tmux does not probe for support and otherwise strips the sequence, leaving the bare title; the declaration reaches clients attached after it is set. Claude Code itself passes OSC 8 through, and a terminal without support ignores it.

## Reading the figures

**Limits.** `rate_limits` refresh only on an API response, so an idle session — or a rate-limited one, which is exactly when someone checks — keeps reporting the window it last heard about. The windows are account-wide and every session on a login writes that login's cache, so the cache is as fresh as the login's most recently answered session. Once a `resets_at` has passed, the % is marked `?` and no `0h00m` countdown is printed; `--guard` and `--wait guard` treat that window as unknown and do not pause on it. The built-in `/usage` fetches live, so it is the tiebreaker when the two disagree.

**Attribution.** Per-session `$` figures are counted: in-window deltas of each session's cumulative API-equivalent cost from `session-log.tsv`. The estimated % splits the global %-movement observed *while sampling was live* by tracked-`$` share; burn before sampling covered a window stays unattributed. The estimate is an upper bound, and the `$` columns stay exact, when some usage renders no statusline — headless `claude -p` runs, and anything off this machine (claude.ai, another device) — since both inflate the tracked sessions' shares. Cross-model splits assume limit weights track API prices. Right after a reset or a fresh install expect `≈0.0%` until the global % moves; `n/a` means no coverage basis yet. Subagent burn lands in the parent session, which is correct; tmux teammates are tracked individually.

**Time.** An interrupted turn may never get its end event: it shows as *unclosed* and adds no time, so active is a floor. A trailing *open* turn shows its age. Messages queued mid-turn fire extra turn starts and inflate *unclosed* slightly.

## The data root

Mode 700, files 600, and a `.gitignore` containing `*` (written by both the installer and the statusline): the store holds session ids, titles, working directories and costs, which must not end up in a commit if the root sits inside a repository.

| Path | What it is |
|---|---|
| `turn-log.tsv` | turn and lifecycle events, one row per event |
| `session-log.tsv` | per-session cost/token samples, written by the statusline |
| `focus-log.tsv` | focused-tab flanks and activity marks, from the tmux hooks and the cron tick |
| `switch-log.tsv` | one row per decision about which login the box runs on, and the switcher's own control state |
| `last-status.<login>.json` | the rate-limit cache, one per subscription login |
| `fable.<login>.json` | that login's Fable weekly cap, fetched by `session account` |
| `probe-body.<login>.json` | the raw usage-endpoint response of the last probe of that login from which no rate-limit window could be read; removed as soon as one can |
| `sessions/<sid>.json` | `{"session_name": …}` — the session's title |
| `sessions/<sid>.cost` | dedup state for the sample log: content is the last logged cost, mtime the last sample time |
| `sessions/<sid>[.p<pane>].limits` | the rate-limit tuple this session last saw, and which login owns it |
| `panes/<pane-id>` | the tmux pane → session id map, so a focus row can name the session |
| `archive/<same names>` | rows older than 8 days, append-only and never expired |
| `resume-queue.tsv` | the snapshot `session reboot` leaves for `session resume` |
| `title-index.tsv` | `sid<TAB>title` for every titled transcript in the store, which `session id <title>` reads once the usage snapshots miss. Built on first use and refreshed per query for transcripts modified since; delete it to force a rebuild |
| `.session-log-pruned` | the once-a-day marker both producers share |
| `<log>.lock` | zero-byte lock files the prune takes; safe to ignore, never to delete while a prune is running |
| `switch.lock` | the decision mutex: one decision at a time, box-wide. Zero bytes, and neither locking backend writes to it, so its mtime is the first decision this root ever took rather than the current holder's — which is why `session doctor` reports whether it is free and never how long it has been held |
| `.probe.<pid>/` | the scratch directory a decision removes on its way out, holding the parallel probe's per-login result files. One left behind is a process that died mid-decision; nothing reaps them, and each holds no token |

**Retention.** The three live logs keep 8 days so every reader stays fast; older rows move to `archive/` under the same file name, and history is deliberately permanent. The prune runs at most once per 86,400 s behind `.session-log-pruned`, under a lock, and is callable from **both** producers — the statusline render and `session --session-end` — so the logs stay bounded whether or not the statusline is installed. `sessions/` and `panes/` are swept of files older than 8 days in the same pass.

`switch-log.tsv` is exempt, and keeps everything: one row per decision, the holds a cooldown turns away included, is too little to need bounding, and each row is the only account of why the box moved off a login, which is a question asked months later or not at all. It is also the switcher's control state — the cooldown and the post-switch probation are both read back out of it — so a prune would be deleting state, not history.

### TSV schemas

**`turn-log.tsv`** — 6 columns, `-` where a field does not apply: `ts` (epoch seconds), `sid`, `ev`, `prompt_id`, `detail`, `agent_id`.

| `ev` | Event | `detail` |
|---|---|---|
| `s` | turn start (`--hook`) | — |
| `e` | turn end (`Stop`) | — |
| `f` | turn failed (`StopFailure`) | the API error type; `rate_limit` marks the moment a cap bit |
| `x` | session end (`SessionEnd`) | the reason |
| `a` / `z` | subagent start / stop | the agent type; `agent_id` pairs them |
| `c` | compaction (`PostCompact`) | `manual` or `auto` |
| `p` | permission prompt shown (`Notification`) | — |

Turn wall time is `e` minus `s`, tool execution included; the gap from an `e` to the next `s` is time between turns. The payload cannot give either figure (`cost.total_duration_ms` ticks through idle time, `total_api_duration_ms` leaves out tool time), which is why hooks mark the boundaries. Each lifecycle mode appends exactly one row, exits 0 and prints nothing, with field values `@tsv`-escaped; `--hook` writes the `s` row even when there is no rate-limit cache yet.

**`focus-log.tsv`** — 6 columns: `ts` (epoch seconds with milliseconds), `ev`, tmux client, tmux session, pane, session id. `ev` is `in`, `out` or `act`; a `switch` hook resolves the focused client and logs an `in`. The session id is resolved from the pane map **at log time**, so later pane-id recycling cannot rewrite history. Millisecond precision keeps rapid switches ordered, since the tmux hooks run asynchronously through `run-shell -b`.

**`session-log.tsv`** — 21 columns, and readers must tolerate shorter lines from older rows: `ts`, `sid`, `cost_usd`, `five%`, `week%`, `five_reset`, `week_reset`, `duration_ms`, `api_duration_ms`, `total_output_tokens`, `total_input_tokens`, `context%`, `cache_read`, `cache_creation`, `cur_input`, `cur_output`, `lines_added`, `lines_removed`, `model_id`, `prompt_id`, `account`. The attribution estimator reads columns 1–8; column 8, the process's cumulative wall clock, distinguishes two processes rendering under one session id (a `--resume` beside a live original), so cost deltas are taken within one process. Column 21 separates two subscription logins, since rate-limit windows are per login. The other columns are logged for later views. A row is appended when the session's cumulative cost moves, plus a 10-minute idle heartbeat.

**`switch-log.tsv`** — 8 columns, `-` where a field does not apply and never an empty one: `ts` (epoch seconds), `ev`, `from`, `to`, `trigger`, `reason`, `figures`, `detail`.

| `ev` | Event |
|---|---|
| `switch` | the box moved from one login to another |
| `hold` | a decision ran and moved nothing; `reason` says why |
| `fail` | a swap was attempted and the post-condition did not observe it |
| `refuse` | a save or a decision was declined before anything was written |

`reason` is a closed enum, and a row carries one member of its event's set:

| `ev` | `reason` |
|---|---|
| `switch` | `climbed` — the target stood strictly higher on the capability ladder |
| `hold` | `cooldown` (another decision ran within 900 s) · `live-clean` (the live login came back verified under 100% on every window, so the death was transient) · `no-candidate` (nothing stood higher) |
| `fail` | `swap-write-failed` · `swap-not-observed` (the write returned but what landed is not the target's credential) · `swap-refused` (the entry cannot authenticate — candidate screening excludes such an entry, so a row carrying this means something upstream of the swap changed) |
| `refuse` | `blank-credential` — a save rather than a decision: the live access token was empty and the vault entry was left alone |

The decision verb's own refusals (`off`, `bad-mode`, `no-credentials`, `too-few-logins`), its `not-writable` and `lock-unopenable` holds and its argument errors (`bad-trigger`, `bad-option`) reach its `k=v` output and never this file: each returns before the cooldown gate, `not-writable` is the case where there is nowhere to write, and `lock-unopenable` is one where no decision was taken to record.

`trigger` is `cap`, `auth` or `manual`. `figures` is `login=5h/wk/fb` per login, joined by `;`, with `*` marking a figure verified against the usage endpoint rather than read from a cache. `detail` is a `k=v;` bag over `sid=`, `http=`, `tier=`, `next_eligible=`, `scoped=` and `notify=`. There is no `dead` event and no `recov=` key.

A reader after one of the `detail` keys must take the newest row **that carries it**, not the newest row: a refusal and a cooldown hold carry neither `next_eligible=` nor `scoped=`. Rows must be split with `awk -F'\t'` and never with `read` — tab is IFS whitespace, so `IFS=$'\t' read` strips a leading tab and merges a run of them, and one empty field would shift every field after it, reading one login's windows as another's. That hazard is also why the writer puts `-` in every field a caller left empty.

**`resume-queue.tsv`** — 3 columns: session id, launch directory, title.

### What is persisted, and what is not

Only what a reader needs is written; the rest of each source is dropped.

**The cache** is `jq -c '{rate_limits, context_window, model, version}'` of the statusline payload. The payload's `cwd`, `transcript_path`, `workspace`, `session_id`, `cost` and the rest are not stored, since nothing reads them.

**The snapshot** is `jq -c '{session_name}'`, all that `session name` and the peer lookup read.

**The Fable file** is `{"fable":{"used_percentage":N,"resets_at":EPOCH}}`, the usage endpoint's one Fable row with its reset in epoch seconds. A response without that row writes nothing; spend, credit balances and the other meters are dropped.

All three are written to a temp file named with the writer's pid in the same directory and moved into place, so a reader never sees a partial file, even when renders on one login overlap. A malformed payload leaves the previous cache byte-identical.

### `time --json` — the contract a task logger reads

```json
{"sid":"…","date":"2026-08-31","day":"today","turns":0,"active_s":0,"longest_s":0,
 "unclosed":0,"open_turn_s":0,"failed":0,"prompts":0,"subagents":0,"waits_s":0,
 "attended_s":0,"attended_basis":"active","watched_s":0,"ended":0}
```

Four fields are the contract: `date` is a `%F` string, `attended_s` and `active_s` are integers, and **`attended_basis` is `focus` or `active`**. Nothing else is promised, and the rest of the object may change — `day`, for instance, is `today`, `yesterday` or the `%F` date of the audited day, and nothing reads it. `session doctor` check 6 asserts all four by running the command. A consumer should be laxer than the contract — require only `date` and `attended_s`, default `active_s` to 0 and an absent `attended_basis` to `focus` — so a build predating either field still books rather than refusing. Zeros rather than an error when nothing is logged yet, so a caller can always take a delta — but the command still **exits 1 while the turn log has no rows at all**, which is the "measurement was never on offer" state described above.

`attended_basis` depends on one thing: whether the **live** focus log has any rows. With focus rows, `attended_s` is focused-tab time, idle-capped at `SESSION_ATTEND_GRACE`. Without them nothing measured attention, so rather than report a zero (which reads as "you were not there") the basis says `active` and `attended_s` equals `active_s`, the turn span. That figure is an upper bound on attention, not a measurement of it: a task logger should book it as an estimate, `~11m`, never `11m04s`.

A machine that had focus tracking but has logged no focus rows for longer than the 8-day retention reports `active` too: its tmux hooks have stopped firing.

### Reads inside the retention window

`session time` reads the live log alone when the requested day is within the last 7 days **and** the live file's first row predates that day's midnight; otherwise it reads `archive/` too, which is about twice as slow on a large store.

## Focus tracking

Attended time needs tmux and five lines the installer does not write for you, since your tmux config and crontab are yours to edit. It prints them at the end of every run, with the absolute path of the linked CLI in place of `session`. Add the four `set-hook` lines to `~/.tmux.conf` and the last line to your crontab:

```
set-hook -g "client-focus-in[0]"        "run-shell -b 'session --focus-mark in  #{hook_client}'"
set-hook -g "client-focus-out[0]"       "run-shell -b 'session --focus-mark out #{hook_client}'"
set-hook -g "client-detached[0]"        "run-shell -b 'session --focus-mark out #{hook_client}'"
set-hook -g "session-window-changed[0]" "run-shell -b 'session --focus-mark switch #{hook_session_name}'"

* * * * * session --focus-mark tick
```

Then `tmux source-file ~/.tmux.conf`. Without them everything else still works, and `attended_basis` says `active`.

The tick logs an activity mark, stamped with the client's actual input time, for every client with input in the last 90 seconds, focused or not; typing and scrolling both count (tmux mouse mode makes wheel events input). Attention stops accruing `SESSION_ATTEND_TAIL` seconds after the last interaction, so a tab left focused on an empty desk does not count. Another scheduler works in place of cron: `--focus-mark tick AGE` sets the recency window, which should be one tick interval plus some slack.

`--focus-mark` exits 0 and says nothing on a host without tmux — it runs from a tmux hook and a cron line, neither of which has a reader.

## Accounts

`session account` lists every vaulted subscription login with its rate-limit headroom and reset countdowns; `use <substring>` swaps the live login in place, atomically, effective on the next request in every session sharing the config dir. Adding a login is just `/login`: the statusline vaults whatever you log into within a render, and the login it replaces was vaulted while it was live, so switching back never re-authenticates. Vault at `SESSION_ACCOUNTS_DIR`, superseded copies under `.history/`.

The list is a table:

```
         #  LOGIN                                    5H    RESET   WEEK  RESET    FABLE  AGE
  live   1  me@example.com                           62%   4h10m   72%   4d00h    100%   now
         2  me@example.com+example-org               ~0%   ?       45%   2d14h    83%    4h
         3  team@example.com                         -     -       -     -        n/a    -
```

`live` in the first column marks the login every session here is using.

| Column | Content |
|---|---|
| `5H`, `RESET` | the 5-hour window's used % and time to its reset; `~0%` and `?` once that reset has passed, or once a cache that carried no 5-hour window is older than five hours |
| `WEEK`, `RESET` | the all-models weekly window's used % and time to its reset; `~0%` and a `~` countdown once it has passed |
| `FABLE` | Fable's weekly cap, used %; `~0%` once its reset has passed. It resets with `WEEK`, so it has no countdown column |
| `AGE` | the age of the row's oldest figure: `now` under two minutes, then `Nm`, `Nh`, `Nd` |

`n/a` is a window the source did not carry. `-` is no data at all: `5H` and `WEEK` come from the statusline cache, which a login gets only once a session has rendered on it.

**`FABLE` is Fable's own weekly cap**, which the statusline cannot record: the payload carries only the 5-hour and all-models weekly windows. Its source is `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind `/usage`, whose `limits[]` lists it as a `weekly_scoped` row with `scope.model.display_name` `Fable`. The endpoint is undocumented. `list` and `use` fetch it for every vaulted login whose `claudeAiOauth.expiresAt` is more than a minute away, in parallel, 5 s each, with that login's own access token passed to curl on stdin (`-K -`), never in argv. `use` fetches after the swap, never before it.

- **A lapsed token is not sent and not refreshed.** A refresh goes through Claude Code's undocumented token endpoint and spends a single-use refresh token, so a new pair lost before it reaches the vault loses that login until its next `/login`; on the live login it would rotate the credential every running session holds. The login's last fetch is listed instead, and `AGE` shows how old it is when it is the row's oldest figure. That figure misses anything the same account spent from another device since.
- **Anything short of a Fable row with a numeric percent keeps the previous file.** That covers curl failing, an HTTP error, a 200 whose body has no `limits[]` (the endpoint's in-band error shape), and a well-formed `limits[]` with no usable Fable row. The endpoint is undocumented, so a missing row is not treated as evidence that the figure went away.
- **`n/a` in `FABLE`** means no fetch has ever succeeded for that login.

**A login is named by its email, and a seat in a Team or Enterprise organisation by `<email>+<org slug>`** (`me@example.com+example-org`). One email can hold a personal plan and a seat at once, with separate credentials and separate rate-limit windows, so the two must never share a vault entry or a cache. A personal plan (`claude_max`, `claude_pro`, `claude_free`, or no organisation recorded) keeps the bare email. The vault file, the statusline cache and the session log's account column all carry that name. `use` takes a row number, the whole name (which always wins, since a bare email is a prefix of its own seat's name) or a unique case-insensitive substring; rows are numbered in C-collated name order, so a number keeps meaning the same login until an entry is added or removed.

**A vault entry that cannot authenticate is never installed.** Before anything is vaulted or written, `use` refuses an entry whose `claudeAiOauth.accessToken` is empty, `null` or absent, naming the login and pointing at `/login` — the remedy is a fresh login, not a retry. Nothing moves: the live credentials and the identity file are left exactly as they were.

**The swap is read back before `use` reports it.** After writing, the installed `claudeAiOauth` is compared with the vault entry's, out of `.credentials.json` rather than out of `.claude.json` — the identity file is a head start for the next statusline render, not the source of truth, and a concurrent session can rewrite it from memory. A mismatch exits 1 with a message naming the file, and neither the confirmation nor the table is printed; the Fable refetch does not run. The comparison is a boolean, so no token value is ever rendered. **`.claude.json` is written before the check**, so after a mismatch it names the login whose credential did not land — `session account list` marks that login `live` until a swap succeeds.

**This is the one platform-bound feature.** It swaps `claudeAiOauth` inside `<config dir>/.credentials.json` and `oauthAccount` inside `<config dir>/.claude.json`, which is where Linux stores them. On macOS they are in the Keychain, the hot-swap property is unverified and probably absent, and building that branch needs a Mac. So on a config dir with no `.credentials.json`, `use` refuses naming the Keychain and pointing here, `save` exits 1 with "nothing to save", and **`session account` still lists the vault with each login's cached headroom**. Nothing here has run on a Mac.

The statusline's autosave calls `<clone>/session account save` whenever the live credentials are newer than the vault entry, and never when the login reads as `unknown`. It is `|| true`-guarded, so a `statusLine` pointing at a clone whose `session` has gone missing silently saves nothing; `session doctor` check 2 catches that.

**A live credential that carries no usable access token is never vaulted.** `save` exits 1, writes the reason to stderr and leaves the existing entry byte-identical. The test is `claudeAiOauth.accessToken` alone: a non-empty one vaults whatever else the object holds, `expiresAt` included; an empty, absent or `null` one is refused, whether `expiresAt` reads 0, is absent, or the other six keys are perfectly well-formed. While the live token is blank, `session doctor` prints a `credentials` FAIL: it names the vault entry to restore with `session account use <login>` when that entry carries a token of its own, and otherwise says no vaulted copy does, since a vault entry can itself be blank.

### Automatic switching

```
session account auto [--trigger cap|auth|manual] [--sid SID] [--dry-run]
```

One decision, box-wide, taken under `switch.lock` in the data root, about which vaulted login this machine runs on: concurrent invocations produce exactly one swap and the rest report busy. Its automatic trigger is the `StopFailure` half of the auto-resume pair — a turn that dies on a usage cap or on an authentication failure reaches a decision before the waiter arms a sleep — and no other event reaches it. Running the verb by hand takes the same decision, recorded with `--trigger manual`. `--sid` names the session the decision is for and is recorded on the row as `sid=`; it changes nothing else.

Four conditions refuse before any network call and before anything is written: `SESSION_AUTO_SWITCH` recorded `off`, `SESSION_AUTO_SWITCH` holding a word that is neither `on` nor `off`, no `.credentials.json` to swap, and fewer than two vaulted logins.

**A switch has to climb a capability ladder.** The 5-hour and weekly windows gate every model; the Fable weekly gates only Fable. So each login sits on one of three rungs, decided by which of its windows are spent, i.e. at 100% (not at `USAGE_WARN_PCT`, which only decides when a session is warned — a login at 90% of its week still has work in it):

| Tier | Blocked | What that login serves |
|---|---|---|
| 2 | nothing | every model |
| 1 | Fable only | every model except Fable |
| 0 | the 5-hour or the weekly window | nothing, whatever the model |

The box moves only onto a login standing **strictly** higher than the one it is on. Equal tiers never switch, however much more headroom the other login has: percentages alone do not authorise moving every session on the machine, and the ladder is its own hysteresis, because the login just left sits lower by construction.

Unknown windows are read in opposite directions on the two sides, and both directions are deliberate. For a **candidate**, an unreadable 5-hour or weekly window is blocked and an unreadable Fable window caps it at tier 1 — so **a tier-1 target has not necessarily spent its Fable quota**; it may be one nothing could read, which is why the wake-up and the notification state the capability and never a figure. For the **live** login, unknown is not blocked: a live login that is merely unreachable is the network-down case, and reading it as blocked would manufacture a switch out of an unreachable endpoint.

Exit codes: **0** switched, **3** held, **4** refused, **5** error. **Never 1** — 1 and 75 are the two locking backends' busy codes, so a caller reads either as "another decision holds the lock" and falls through with no retry and no look at the log, whose newest row describes some earlier decision. A lock file that cannot be **opened** is not busy — busy clears by itself and that does not — so it is reported as a `hold` naming `lock-unopenable` rather than passed back as the backend's own code, which nothing branched on. Every outcome prints the same six lines:

```
ev=switch|hold|refuse|fail|dry-run
from=<login>|-
to=<login>|-
reason=<word>
tier=<the tier the box lands on: 0|1|2|->
next_eligible_at=<epoch>|-
```

`--dry-run` prints a table above those lines — a `live=` row and one `cand=` row per login the decision is choosing among, each as `<login>/<tier>/probe|frozen/<5h>/<wk>/<fb>` — and sends no notification and swaps nothing. Like `session account list`, it refreshes the per-login caches it reads. The rows are not in rank order and the winner is named by `to=`, not by its position; a vault entry the screening below rejected has no row at all, which is the thing to know when asking why it will not move to one particular login. Its `ev=` reads `dry-run` and it exits 3, like any hold. The one file it does create is `switch.lock`, because taking the mutex is what serialises it against a real decision.

**A hold is a decision that ran and moved nothing**, and past the cooldown gate it leaves a row like any other outcome. Every such hold carries `next_eligible=`, the earliest epoch at which any rejected candidate would climb above the live login's tier; only a candidate that probed `good` can contribute one, because the frozen path renders countdowns and drops Fable's reset outright, so the value is `-` when none did — as it also is on a `live-clean` hold, which never looks.

`cooldown` means a decision ran within 900 s. That window is measured against the newest row this verb itself wrote, which is why neither a blank-credential refusal nor an earlier cooldown hold starts the clock: refusals arrive one per login per cooldown through exactly the outage the feature exists for, and counting a cooldown hold would slide the window forward on every retry and end it never. A switch — or a swap that wrote the identity file before the credential check failed — puts that target on a 600 s probation that bypasses the cooldown, so a second death on the login just moved to re-decides at once rather than waiting a quarter hour out.

**Each login is probed with the token that serves it**, against the same `GET https://api.anthropic.com/api/oauth/usage` the `FABLE` column uses. The live login goes first, with the live `.credentials.json`, since that is the token actually serving requests; the candidates follow in parallel, 5 s each. A vault entry is screened out before any token of its own is sent when it carries no usable access token, when its `expiresAt` reads 0, or when its access token is the one already live. Such an entry is silently not a candidate: `session doctor`'s `switcher` line counts how many vault entries carry a token at all, and its `vault` line names an entry holding the **installed** access token under another login's name, which a half-finished swap leaves behind. While that entry stands, every decision holds on no candidate; the line names the file and the `session account use` that ends it. The probe's state decides whether a login's figures are fresh or frozen, and is classified on the HTTP status alone:

| State | What happened |
|---|---|
| `good` | 200 with at least one readable window. The only state that supplies reset epochs, and the one that refreshes `fable.<login>.json` |
| `dead` | **401 or 403 only** — the credential was rejected |
| `unreachable` | 429, 408, 5xx, anything else, or curl failing. A 429 is a 4xx and must never read as `dead`: this endpoint's rate bucket is selected by User-Agent, so a throttle read as a rejection would mark healthy logins dead |
| `noshape` | 200 that no window could be read from. The body is kept as `probe-body.<login>.json`, and a later `good` probe of that login deletes it, so the file always describes the *last* unreadable response |
| `lapsed` | the access token expires within 60 s, or the entry carries none. Nothing was sent, so nothing is known — `dead` would claim the endpoint rejected a token it never saw |
| `nocurl` | no `curl` on `PATH` |

A candidate the endpoint answered `dead` for is never ranked on its cached figures — a credential just rejected can look excellent in a cache, and that is exactly how a dead one goes live. A live login answered `dead` is read as blocked on every window, which is the authentication-failure path. Every other non-`good` state falls back to that login's frozen figures.

**Announcing the move.** `SESSION_SWITCH_NOTIFY`, when it names an executable, is run with one argument — for a switch, a sentence naming both logins and what the new one serves — on a switch and on a blank-credential refusal, never on a hold: holds are the normal outcome, several a day in a Fable-capped week. It runs detached and only after the decision lock is released, so a notifier that hangs delays nothing and blocks no later decision.

**A blank credential met while switching is recorded, not pushed.** The statusline's autosave, where nobody is watching, pushes its refusal; the save a swap makes of the login being replaced — on `session account use` as on an automatic decision — writes the row and sends nothing, and on `use` that row is the whole record. The row starts the refusal's 900 s cooldown either way, so an autosave refusing the same login inside it writes nothing and sends nothing.

**Why the box moved.** Every decision past the cooldown gate leaves one row in `switch-log.tsv` under the data root (`session doctor` prints the resolved root), and that file is never pruned, so a switch months old still has its row: both logins, the trigger, the reason, every login's figures at that moment, and `tier=` in the detail bag. The schema is under [TSV schemas](#tsv-schemas). `session doctor`'s `switcher` line prints the newest decision beside the newest cap death, so a cap death with no decision beside it reads as a gap rather than as a hold.

**Turning it off, in order.** `uninstall.sh` is *not* the lever — it removes the rewake pair wholesale and takes auto-resume with it.

1. Append `SESSION_AUTO_SWITCH=off` to `<config dir>/session.conf`. The conf is read on every invocation and each decision is a fresh child, so the next cap death already sees it; nothing restarts. A re-run of the installer keeps the line; deleting it is what puts the machine back.
2. To take the code out as well, `git checkout <sha> -- session lib/account.sh` in the clone. The hook command is an absolute path resolved at exec time, so every running session picks that up within seconds too.

Write that line with your own editor, never with `sudo`: it changes the file's owner, the lib then skips the **whole** conf rather than the offending line, and the switcher stays armed while every other recorded value — `SESSION_DATA_DIR` first among them — silently reverts to its default. `session doctor` check 3 is what names a conf the lib is skipping.

**A quiet week is not a fault.** In a week where every login's Fable quota is spent, every login sits at tier 1 or below, nothing climbs, and every decision holds — the policy working, not an install that is broken. The authentication trigger is the one that moves the box out of a blank-credential outage.

**On macOS the decision refuses**, naming the Keychain, for the same reason `use` does: there is no `.credentials.json` to swap. Without `curl` a decision still runs, on the frozen figures in the per-login caches.

## Reboot and resume

`session reboot` snapshots every live interactive session to the resume queue and reboots (`sudo systemctl reboot`, or `sudo shutdown -r now` where there is no systemctl); `session resume` reopens one tmux window per snapshotted session and clears the queue. `--scan [HOURS]` is the recovery path when no snapshot was taken, reading the transcript store instead. `-n` prints without doing anything.

Both **refuse with a message naming tmux** when tmux is absent. `session peers` works without tmux (it reads Claude Code's presence registry), and `--focus-mark` is a silent no-op.

`SESSION_TMUX_MAIN_GUARD`, when set to an executable, runs before `resume` opens windows: a host's own pre-resume check. Running `session resume` automatically at boot needs a service unit, which is the host's business and not this installer's.

## Auto-resume: `--rewake-waiter` and the ⚠ advisory

Two `asyncRewake` entries, on `UserPromptSubmit` and `StopFailure`, armed by default. Once a window crosses `USAGE_WARN_PCT` (default 90) — or a turn dies on a cap — the entry becomes a waiter that wakes the session when the window resets or the login switches. **Its exit 2 is the wake signal**, delivered through the task-notification channel. `--no-rewake` opts out; `uninstall.sh` removes them.

**Only the wake-up itself writes to that entry's stderr**, because exit 2 hands stderr to the model as a message. So a configuration the waiter cannot read — a guard spec, `USAGE_WARN_PCT`, an unknown argument — exits 0 there silently and arms nothing. The synchronous `--hook` entry is what surfaces it, refusing every prompt until it is fixed. `session doctor` names a bad warn threshold but not a bad guard spec: it runs before the guard specs are read. One malformed line in `session.conf` reaches every session on the machine.

**The version gate fails closed.** The pair is armed only when `claude --version` reports at least 2.1.233, the build the backgrounding behaviour was verified against, compared as dot-separated integer tuples rather than as strings (`2.1.99` is older than `2.1.233`). Below it, and **when there is no `claude` on `PATH` at all**, the pair is refused with a remedy rather than armed blind — a harness that does not background an async hook would run the waiter synchronously on every over-threshold prompt, blocking it there until the window reset. The lifecycle entries still land in every refusal case. A teammate installing from a shell where `claude` is not on `PATH` will hit this; the remedy is to fix `PATH` or pass `--no-rewake`.

**The pair's `timeout` is not enforced** — an `asyncRewake` entry is backgrounded and runs to completion — so **anything in the waiter that can block is bounded inside the script**, by its own sleep arithmetic and guards.

**`rewakeMessage` and `rewakeSummary` are undocumented-but-observed fields.** They are embedded as literals in `install.sh` and match what live entries carried when they were observed. Re-verify them after a Claude Code upgrade.

**The advisory.** At or above the threshold, `session --hook` injects one advisory, the same for every window except a lead sentence naming the window that crossed, telling the model that a cap is no reason to stop, wind down or hold back parallel work because a waiter is armed. The sentence promising an armed waiter appears only when `settings.json` carries a `rewake-waiter` entry with `asyncRewake: true`.

**A cap death decides before it sleeps.** On `StopFailure` the entry first runs `session account auto` — see [Automatic switching](#automatic-switching) — above everything else: above the arming below, which exits outright when the cache names no future reset, and above the one-waiter-per-session dedup. Every spawn reaches that decision rather than only the one that becomes the waiter, so a session whose waiter is already asleep can still rescue the box; the lock and the cooldown reduce the fan-in to one real decision, and a spawn that finds the lock busy falls through to the ordinary waiter with no retry. If the box moved, the deciding session is woken at once with a message naming both logins, and the sessions that were already asleep are woken by the same config-directory check that already picks up a manual `session account use` — within a second or two where `inotifywait` exists, within fifteen where it does not. That message says what the new login serves: on a move to a tier-1 login it says so in a sentence, because a resumed subagent keeps the model it died on, and a Fable session told only that the cap is gone would retry on Fable and die on the same cap again. An **authentication** death that does not switch then exits without arming anything — no reset lifts an authentication failure, so there is no time to sleep to. A **cap** death that does not switch falls through to the target selection below.

**Which reset the waiter sleeps to, when a cap death is all it has to go on.** Neither generic window warned means the cache cannot say which cap killed the turn, so the target is chosen in three steps. The live login's Fable weekly window comes first: if `fable.<login>.json` puts it at or above `USAGE_WARN_PCT` with its reset more than a minute out, that reset is the target and the wake-up names the Fable window. Otherwise whichever generic reset is still ahead — the 5-hour one first, the weekly otherwise. No future reset anywhere and the waiter does not arm at all.

The Fable step is there because that window gates only Fable and no generic reset lifts it: a waiter armed on the 5-hour reset after a Fable cap wakes, retries and dies again. Its reach is bounded by where the figure comes from. Three things write that file — `session account list`, `session account use`, and every decision whose live probe comes back `good` — and the statusline's autosave is not one of them. On this path the decision has just run, so the figure is current whenever that probe answered `good`; the retarget falls back to a stale one only where the decision never probed at all, which is a refusal, an error, a cooldown hold or a busy lock. A stale *low* figure suppresses the retarget and the waiter behaves exactly as it would with no file at all; a stale *high* one is still true, because Fable rises only while its login is live and otherwise resets weekly. The arming step itself fetches nothing, deliberately: past the decision, a slow endpoint must never stand between a capped session and its wake. What remains is the weekly fall-through — a `rate_limit` death with a stale 5-hour reset and no spent Fable window genuinely can be the weekly cap, and sleeping to a reset up to seven days out is the one path where the waiter can outlive its usefulness by days.

**A hold can shorten that sleep, and waking early is not a reset.** A hold that found no candidate names `next_eligible_at`, the time its best rejected candidate would climb above the live login, and the waiter sleeps to that instead when it is further out than the decision cooldown and nearer than the target. Below the cooldown it is refused rather than clamped: a re-decision taken before the hold that named it has aged out can only hold on the cooldown again, so waking there buys a subprocess and an audit row and nothing else. Waking early, the waiter re-decides **once** — on a switch it wakes the session with the switch message, otherwise it goes back to sleep on its **original** target, and its eventual wake-up still names the window that target came from. The loop's "the window has reset" message belongs to the target alone, and no early wake may take it.

## Platform support

Everything has run on Linux. The CLI and the statusline are written for macOS too — bash 3.2, BSD `date` and `stat`, no `/proc`, no `flock(1)` — but the macOS branches have not run on a Mac.

- **Dates.** Day boundaries go through perl, so 23- and 25-hour DST days come out right. Where a DST transition falls at midnight, that local midnight does not exist and the libc picks the direction (glibc forward, musl back), so on a musl host `session time --date <that day>` starts an hour early in those zones.
- **`--date` accepts** `YYYY-MM-DD` and `yesterday`. Free text (`3 days ago`) is passed to GNU `date` where it exists and **refused with the list of accepted shapes** elsewhere, rather than answered with a wrong day.
- **`session time` refuses a day it cannot resolve** (no perl, say) rather than reporting the whole log as today.
- **Process inspection** reads `/proc` where it exists and falls back to `ps`. On a Mac where that cannot see the session's ancestor, `session whoami` refuses cleanly unless `CLAUDE_CODE_SESSION_ID` is set.
- **Locking** uses `flock(1)` where it exists and perl otherwise. On the perl path (macOS), a `switch.lock` this user cannot write makes `session account auto` hold with `lock-unopenable` rather than decide.
- **`curl` is optional**, used only by `session account`: to fetch the `FABLE` column, and to probe each login's windows for an automatic switch. Without it every login lists its last fetched figure, or `n/a`, and a decision still runs — on those frozen figures rather than on what the endpoint says now.
- **The statusline requires `jq`**, and so does the installer.

## Tests

```
bash tests/run.sh [--require-3.2]
```

Three suites, run natively and again under `docker run bash:3.2` when docker is present, the nearest thing here to macOS's `/bin/bash`. `--require-3.2` fails the run when that second leg could not run. `CLAUDE.md` has the rest.

## Removal

```
uninstall.sh [--bindir DIR] [--name NAME]
```

Removes every hook entry of this CLI's shape (another clone's included), the `statusLine` when it is ours, and the symlink when the name resolves to this clone; when nothing of ours is at `--bindir` it also checks what the name resolves to on `PATH`. A foreign `statusLine`, a symlink pointing elsewhere and every other setting are left as they are, and a second run changes nothing.

**The data root and `session.conf` stay.** The data root is your recorded history (the `rm -rf` line is printed, not run), and `session.conf` describes the machine, which a reinstall wants.
