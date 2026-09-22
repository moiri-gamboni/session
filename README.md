# session

The `session` CLI answers what a Claude Code session cannot answer about itself: which session it is, how much of the plan's shared 5-hour and weekly rate limits it has burned, and how much of today's clock was actually spent on it. It is one bash dispatcher plus a statusline that feeds it, wired into a Claude Code configuration by `install.sh` from a clone. `session --help` is the flag reference; this file is the ops contract — what gets installed where, what each file on disk means, which promises are pinned by which test, and what is true only on Linux.

Two things make it more than a status readout. The turn boundaries come from hooks rather than from timestamps in a payload, so idle gaps between turns are excluded by construction and headless `claude -p` runs are counted like any other; and `session time --json` is the measurement a task logger books a worklog beat against, so a broken install here shows up as a fabricated duration in somebody's task folder. That consumer is why `session doctor` exists and why the two allowlists below are pinned rather than described.

## Install

Run `install.sh` from a **git clone**. It refuses to install from a path under `plugins/cache/`, and from a directory the running user does not own. Both refusals are about the same thing: `settings.json` stores whatever path it is given, verbatim and forever, and `${CLAUDE_PLUGIN_ROOT}` is SHA-pinned, rewritten on every `claude plugin update`, and not expanded in settings anyway. A plugin-cache install would point every hook at a directory that stops existing. `statusLine` is not a plugin-settable key either, which is the other half of why this rides a clone rather than the plugin.

```
install.sh [--bindir DIR] [--name NAME] [--force-link] [--dry-run] [--no-rewake]
           [--data-dir DIR] [--main-guard PATH] [--attend-grace SECONDS]
           [--attend-tail SECONDS] [--primary-cfg PATH]
```

Every step prints `ok`, `skip` or `REFUSE <fact> <remedy>`. **A refusal never stops a later step** — a symlink name someone else already holds must not cost you the hook entries — and the exit status is 1 if any step refused. The `session doctor` run at the end is information: its status is deliberately not the installer's, so a fresh install that is correctly `pending` on four checks still exits 0.

What it writes into `$CLAUDE_CONFIG_DIR/settings.json`, all as absolute paths into the clone: eight lifecycle hook entries (`UserPromptSubmit --hook`, `Stop --turn-end`, `StopFailure --turn-fail`, `SessionEnd --session-end`, `SubagentStart --subagent-start`, `SubagentStop --subagent-end`, `PostCompact --compact-mark`, and `Notification --perm-mark` under `matcher: "permission_prompt"`), each `bash <clone>/session --<mode> || true` with `timeout: 2`; the two auto-resume entries; and the `statusLine`. Beside the settings file it creates the data root, links the CLI onto `PATH`, and — when any of the five machine-shape flags is passed — writes `session.conf`. Only two top-level settings keys are ever added: `hooks` and `statusLine`.

**`|| true` on the lifecycle entries is load-bearing and its absence on the rewake pair is too.** A hook command is run through `/bin/sh` (dash on Debian and Ubuntu — probed: `exe=/usr/bin/dash argv0=/bin/sh comm=sh parent=claude`), so the shell metacharacters are interpreted and `|| true` is POSIX. The rewake pair must not carry it, because **exit 2 is the wake signal**: swallowing it leaves a waiter that sleeps out its whole wait and then wakes nobody. Case 26 in `tests/install.test.sh` asserts both on the command strings.

**A re-run is a byte-identical no-op** (case 27). It identifies its own entries by the clone path inside the command rather than by a naming pattern, so an install from any directory layout replaces rather than duplicates. It additionally drops entries of this CLI's shape whose script no longer exists — a clone that was moved or deleted otherwise leaves hooks that fail on every turn — and leaves another clone's live entries alone.

**Refusals to expect** (case 28): a `statusLine` that is not ours is refused, not replaced, with the exact object to merge by hand printed beneath it; a symlink name already taken is refused unless you pass `--force-link` or `--name`; an unparsable `settings.json` refuses every settings step and is left untouched; an absent one is created as `{}`; and a `settings.json` that changed between the installer's read and its write is refused with the remedy to close Claude Code (which rewrites the file at runtime) and re-run. A `settings.json` that is a symlink — a dotfiles repo, say — is followed: the edit and its backup land at the target, and the link survives.

**`--dry-run` writes nothing at all** — no data root, no symlink, no `session.conf`, no settings file — prints the `jq -S` diff of the merge, and stops before the focus-tracking lines and `doctor`, both of which would describe an install that has not happened. On a config dir with no `settings.json` it still diffs, against a virtual `{}`.

**Running Claude Code sessions are unaffected until they restart.** Hook configuration and the `statusLine` are read at session start, which is why the installer ends by saying so. It is also why replacing an older copy of this CLI on the same machine has to leave the old files in place until no session is still pointing at them.

On a shared machine, prefer a clone under your own home. The `statusLine` command is a path this configuration will run on every render; a clone in a world-writable location is a path another user could recreate.

### What each install state delivers

| State | What you get |
|---|---|
| Hook entries only (`statusLine` refused or declined) | `session time` and everything hook-fed: turn counts, active time, waits, subagent spans. No rate-limit figures at all — the 5h/weekly data exists only as statusline stdin, so `session`, `session usage`, `--guard` and `--wait` have no cache to read and exit 1. |
| Hook entries + `statusLine` | The overview, `usage`, `--guard`, `--wait`, `--compact`, `account`. `attended_s` falls back to active time and says so (`attended_basis: active`). |
| The above + the tmux/cron focus lines | Attended time as focused-tab time, idle-capped at `SESSION_ATTEND_GRACE`; `watched` (active ∩ attended); `attended_basis: focus`. |
| The above + the rewake pair (default) | A session paused by a usage cap wakes itself when the window resets or the login switches. |

Nothing above is required by anything below it, and `session doctor` names which of them this machine currently has.

## How to install it on a machine

**Requirements:** bash and `jq` (the installer refuses without `jq`); `tmux` too if you want the reboot/resume features. `install.sh --help` lists every flag.

**1. Clone the repository** somewhere under your own home; the clone's path is what every hook entry will carry.

```
git clone <this repository> ~/code/session
```

**2. Run the installer from the clone**, with the flags that describe this machine (`install.sh --help` for the full flag reference):

```
~/code/session/install.sh --bindir ~/bin --data-dir ~/.local/share/session
```

Pass `--bindir DIR` when `~/.local/bin` is not on your `PATH` (the installer prints the `export PATH` line when the directory it linked into is not). Pass `--data-dir DIR` when the usage store should live somewhere other than `<config dir>/session-usage` — on a machine that already has a store from an earlier install, point it there and nothing moves. Add `--primary-cfg PATH` when this machine's usual `CLAUDE_CONFIG_DIR` is not `~/.claude`, or every render will be tagged as a secondary login. Add `--main-guard`, `--attend-grace` and `--attend-tail` only if you need them; the [Configuration](#configuration) table says what each moves. Every machine-shape flag is recorded in `<config dir>/session.conf`, so a later re-run without it keeps the value.

**3. Install the plugin for the skill**, box-wide. This is a separate channel from step 2 and neither step implies the other: the clone carries the code and the hook entries, the plugin carries the `/session:session` skill that tells a session when to run it.

```
claude plugin marketplace add <this repository>
claude plugin install session@session --scope user
```

**4. Restart Claude Code**, then use it once. The hooks and the `statusLine` load at session start, and both have to have run before there is anything to measure. `session doctor` then reads `ok` or `pending` on every line; a `FAIL` names what is wired wrong.

**The first `session time --json` on a machine whose turn log is still empty exits 1**, with `session: no turn log yet at <path> (the per-turn hooks append it)`. A task logger reads that as "measurement was never on offer here" and should record the beat as unmeasured rather than as zero. Once a turn has been logged it books `0s` for a delta that rounds to nothing, `~Nm` on a machine without focus tracking, or an exact `11m04s` with focus tracking on.

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

Everything here has been run except the interactive `claude` line, which needs a login. Without it `doctor` reads `pending` on the cache, the turn log and `time --json` — the correct answer for a configuration nothing has run against yet, and the reason the next paragraph matters.

**Two prompts, not one.** A session's first render cannot know whose rate-limit window it is looking at — a fresh session's first payload can already carry another account's — so the statusline records the tuple unowned and writes no cache. The second render, with a moved tuple, is the one that writes it. A single prompt leaves `session` correctly reporting no cache. Case 20 in `tests/statusline.test.sh` pins that shape.

Then `uninstall.sh --bindir "$BINDIR"`, which should leave the scratch `settings.json` as `{}`.

## `session doctor`

Ten checks, each asking whether the thing works *on this machine* and printing the fact it decided on (plus two lines that appear only when they have something to report: a `session.conf` line when that file is broken or ignored, and a `credentials` line when the live access token is empty). Three states, because "not yet" and "wired wrong" have different remedies: **ok**, **pending** (nothing has produced it yet — usually "interact once"), **FAIL** (wired wrong, and the line says what). Only a FAIL exits 1. Case 19 in `tests/session.test.sh` pins all three.

1. **data root** — exists, writable, mode exactly 700, and the resolved path with its candidate sources named (`from SESSION_DATA_DIR`, `…which <conf> also sets`, or the default — sourcing the conf sets the variable, so which one won cannot be known after the fact and the check does not pretend to).
2. **on PATH** — what `session` on `PATH` actually resolves to, FAIL when it is not this file. Two copies of this CLI on one machine is the failure mode the whole check exists for.
3. **settings** — `settings.json` parses, probed once before every check that reads it: FAIL when jq rejects it (everything downstream reads it as empty) or when it exists but cannot be read. Beside it, `session.conf` gets its own FAIL line when it is unreadable, skipped by the lib for a loose mode (named), or not valid shell.
4. **cache** — present, parses, carries `rate_limits`, its age, and the Claude Code version it recorded. FAIL when it is over 120 s old inside a live session (the statusline is not rendering), and FAIL when it is absent while the root carries turn rows **and an effective statusLine of ours is configured for this directory** — hooks-only installs are a supported state and read `pending` here, with the note that the limit tiers stay unavailable.
5. **turn log** — FAIL on turn ends with no starts, which is exactly the shape of a missing `UserPromptSubmit --hook` entry and reads downstream as a worked day with no work in it. A newest start days old is `ok` with its age printed: a quiet weekend is not a fault.
6. **time --json** — runs it and checks the contract a task logger reads, rather than reading the code that writes it.
7. **statusLine** — the **effective** one for the current directory, merging `$PWD/.claude/settings.local.json`, `$PWD/.claude/settings.json` and the config dir's `settings.json`, first hit wins. A project settings file in the directory a session runs from silently outranks yours (this also scopes check 4). Ownership is decided on the command's **last word**, resolved through symlinks — which is why the installer writes `bash <abs>/statusline.sh` with the path last.
8. **session id** — `whoami --id` is a UUID and equals `CLAUDE_CODE_SESSION_ID`.
9. **auto-resume** — the rewake entries, counted across every event. `ok` when every one carries `asyncRewake: true`, FAIL when some do not (those run synchronously and block the prompt) or when `settings.json` exists but cannot be read, `pending` when there are none.
10. **platform** — `perl`, `jq`, `tmux`, `inotifywait`, `flock(1)`, `/proc`, each present or absent with its fallback named. `perl` and `jq` missing is a FAIL; the rest are information. On Darwin it adds a `pending` line for `session account`.

A fresh install reads:

```
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
```

Check 1 names candidates rather than attributing a source: sourcing `session.conf` sets the variable, so after the fact a conf-set root and an environment-set root are indistinguishable, and an attribution would be false exactly when a conf and the environment disagree. The line reads `from SESSION_DATA_DIR`, adding `which <conf> also sets` when a conf names it too.

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
| `SESSION_PRIMARY_CFG` | `$HOME/.claude` | the config dir this machine treats as its primary login |
| `SESSION_NOW` | unset | a fixed "now" for the date layer; tests only |
| `USAGE_WARN_PCT` | `90` | the used % at or above which `session --hook` injects its usage line and ⚠ advisory, `session --rewake-waiter` arms, and a cached Fable figure counts as spent for the waiter's target; a whole number (anything else exits 2), and above 100 turns the hook's output off entirely |

`SESSION_PRIMARY_CFG` is the one that is easy to get wrong. Everything that is not it is a secondary login and gets tagged as one — the ` · <cfgdir>` tag on the statusline and the ` · account <email>` line on the overview. On a machine whose normal `CLAUDE_CONFIG_DIR` is not `~/.claude`, leaving the default means every render on the normal login is tagged as unusual, and the tag stops carrying information. Point it at that machine's own config dir instead.

**`session.conf`, at `<config dir>/session.conf`, is what reaches the contexts that inherit no shell environment**: tmux `run-shell`, cron, systemd units and Claude Code's own hooks. An export in a shell profile reaches none of them, so a machine whose data lives outside the default root needs the file rather than the variable. `install.sh` writes it from `--data-dir`, `--main-guard`, `--attend-grace`, `--attend-tail` and `--primary-cfg`, one line per flag passed, before it touches `settings.json` — so there is no window in which a producer this run wired resolves the default root. Recorded values survive every re-run — a variable this run's flags do not carry is re-emitted from the existing conf — but the file is rewritten whole, so hand-written comments in it do not; treat it as CLI-owned. No flag writes `USAGE_WARN_PCT` — add that line by hand in the same `VAR="${VAR:-value}"` form, and a re-run re-emits it like any other recorded value. With none of the five passed and no conf on disk, none is created. The lib only trusts a conf that is owner-writable alone: the installer writes it mode 600, and `session doctor` FAILs a conf the lib is skipping, naming the mode. Each line is written as `VAR="${VAR:-value}"`, so the environment still wins per variable and setting one never suppresses the others, and a value under the home directory is written as a literal `$HOME` so the file is portable and diffable. The lib reads it **before** filling in the `SESSION_DATA` default.

## The status line

One line: `<model> (<effort>) · <context> tkns, 5h: <pct> (<left>), wk: <pct> (<left>)`, then two segments that appear only when they have something to say — ` · <task>` and the ` · <cfgdir>` login tag above. The rate-limit pair is the account's newest *proven* windows rather than whatever the payload happens to be replaying (the selection rules are in the script's comments); an expired window keeps its percentage and is marked `?`, never zeroed. The `seg:` cases in `tests/statusline.test.sh` pin that.

**The task segment** names whatever task the session is on, its title anchored as an OSC 8 hyperlink to the task's URL, with `↗` marking a linked title. It reads the nearest ancestor of the session's working directory that carries a `tasks/.sync` directory — call that the workspace — and inside it, two signals in order: the task folder containing the session's working directory, else the workspace's `tasks/.sync/session-task.json`, a JSON object keyed by session id. A task-tracking tool can populate that file to point a session at a task without the session's cwd being inside the task's folder; each entry is looked up by the running session's id and read for one key, `slug` — the name of a folder under `tasks/` — so `tasks new`, a promotion or an adoption can point the segment at a task the moment it exists. Outside a workspace, or with neither signal set, the segment shows nothing.

Once a task folder is found (by either signal), its title and link come from two files, tried in order: `identity.json`, a two-key JSON object (`url`, `title`) read as one row via `jq`; or, when that is absent, `task.md`'s first `# ` heading, which gets no link. The title is cut to its headline — the part before `: `, ` — ` or ` - ` when that is a phrase of its own (12+ characters) — then clipped to 40 characters at a word boundary, by code point so a C-locale render cannot split an accented character. A pointer to a folder that no longer exists, or a file that does not parse, shows nothing and costs the line nothing.

Whether the link is clickable is the terminal's business. Claude Code passes OSC 8 through its status line renderer (its ANSI carry-over regex names the sequence). **Under tmux the outer terminal has to be declared capable** — `set -sa terminal-features 'xterm*:hyperlinks'` for a TERM that renders them, such as VS Code's — because tmux forwards OSC 8 only to a client it believes supports it and does not probe for that; without the declaration it strips the sequence and the bare title shows. The declaration reaches clients attached after it is set. A terminal with no support ignores the sequence.

## The data root

Mode 700, files 600, and a `.gitignore` containing `*` — the store holds session ids, titles, working directories and costs, and a clone that ends up inside a repository must not carry them into a commit. Both the installer and the statusline write that `.gitignore`, deliberately: on a machine where the root already exists the statusline's create branch never fires, and on a machine with no statusline the installer is the only writer.

| Path | What it is |
|---|---|
| `turn-log.tsv` | turn and lifecycle events, one row per event |
| `session-log.tsv` | per-session cost/token samples, written by the statusline |
| `focus-log.tsv` | focused-tab flanks and activity marks, from the tmux hooks and the cron tick |
| `switch-log.tsv` | one row per decision about which login the box runs on, and the switcher's own control state |
| `last-status.<login>.json` | the rate-limit cache, one per subscription login |
| `fable.<login>.json` | that login's Fable weekly cap, fetched by `session account` |
| `sessions/<sid>.json` | `{"session_name": …}` — the session's title |
| `sessions/<sid>.cost` | dedup state for the sample log: content is the last logged cost, mtime the last sample time |
| `sessions/<sid>[.p<pane>].limits` | the rate-limit tuple this session last saw, and which login owns it |
| `panes/<pane-id>` | the tmux pane → session id map, so a focus row can name the session |
| `archive/<same names>` | rows older than 8 days, append-only and never expired |
| `resume-queue.tsv` | the snapshot `session reboot` leaves for `session resume` |
| `title-index.tsv` | `sid<TAB>title` for every titled transcript in the store — what `session id <title>` reads once the usage snapshots miss. Built on first use (one scan of the store) and refreshed per query for the transcripts modified since; its mtime is the start of the scan that wrote it. Delete it to force a rebuild |
| `.session-log-pruned` | the once-a-day marker both producers share |
| `<log>.lock` | zero-byte lock files the prune takes; safe to ignore, never to delete while a prune is running |

**Retention.** The three live logs keep 8 days so every reader stays fast; older rows move to `archive/` under the same file name, and history is deliberately permanent. The prune runs at most once per 86,400 s behind `.session-log-pruned`, under a lock, and is callable from **both** producers — the statusline render and `session --session-end` — so the logs stay bounded whether or not the statusline is installed. The marker name is the one the pre-port code used, which is what keeps a machine being cut over from pruning immediately on day one or orphaning the old marker. `sessions/` and `panes/` are swept of files older than 8 days in the same pass.

`switch-log.tsv` is exempt, and keeps everything. Counted over the whole recorded history, decisions that survive the cooldown run at about 1,500 rows a year against a 79 MB store, so there is nothing to bound; and each row is the only account of why the box moved off a login, which is a question asked months later or not at all. It is also the switcher's control state — the cooldown, the failed-switch probation and `next_eligible_at` are all read back out of it — so a prune would be deleting state, not history.

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

Turn wall time is `e` minus `s`, which includes tool execution; gaps between an `e` and the next `s` are unattended time. Neither figure is available from the payload: `cost.total_duration_ms` is session wall clock and ticks through idle, and `total_api_duration_ms` excludes tool time. Case 2 pins that each of the seven lifecycle modes appends exactly one row, exits 0 and prints nothing — including when a field carries a tab, a newline or a whole forged row, which `jq @tsv` escapes. The `s` row comes from the eighth entry, `--hook`, and case 4 pins that it is written **before** the cache check rather than after: a `--hook` that returned early on a missing cache produced a log with ends and no starts, which reads downstream as a worked day with no work in it.

**`focus-log.tsv`** — 6 columns: `ts` (epoch seconds with milliseconds), `ev`, tmux client, tmux session, pane, session id. `ev` is `in`, `out` or `act`; a `switch` hook resolves the focused client and logs an `in`. The session id is resolved from the pane map **at log time**, so later pane-id recycling cannot rewrite history. Millisecond precision keeps rapid switches ordered, since the tmux hooks run asynchronously through `run-shell -b`.

**`session-log.tsv`** — 21 columns, and readers must tolerate shorter lines from older rows: `ts`, `sid`, `cost_usd`, `five%`, `week%`, `five_reset`, `week_reset`, `duration_ms`, `api_duration_ms`, `total_output_tokens`, `total_input_tokens`, `context%`, `cache_read`, `cache_creation`, `cur_input`, `cur_output`, `lines_added`, `lines_removed`, `model_id`, `prompt_id`, `account`. Only 1-8 are read by the attribution estimator — 8, the process's cumulative wall clock, distinguishes two processes rendering under one session id (a `--resume` beside a live original), so a cost delta is taken within a process and an alternation between them is never booked as spend; the rest are logged so the history exists when a view wants it. Column 21 is what keeps two subscription logins from mixing, since rate-limit windows are per-login. A row is appended when the session's cumulative cost moves, plus a 10-minute idle heartbeat — case 21 pins one row per changed cost and none on an identical render.

**`switch-log.tsv`** — 8 columns, `-` where a field does not apply and never an empty one: `ts` (epoch seconds), `ev`, `from`, `to`, `trigger`, `reason`, `figures`, `detail`.

| `ev` | Event |
|---|---|
| `switch` | the box moved from one login to another |
| `hold` | a decision ran and moved nothing; `reason` says why |
| `fail` | a swap was attempted and the post-condition did not observe it |
| `refuse` | a save or a decision was declined before anything was written |

`trigger` is `cap`, `auth` or `manual`. `figures` is `login=5h/wk/fb` per login, joined by `;`, with `*` marking a figure verified against the usage endpoint rather than read from a cache. `detail` is a `k=v;` bag over `sid=`, `http=`, `tier=`, `next_eligible=`, `scoped=` and `notify=`. There is no `dead` event and no `recov=` key.

A reader after one of the `detail` keys must take the newest row **that carries it**, not the newest row: a refusal and a cooldown hold carry neither `next_eligible=` nor `scoped=`. Rows must be split with `awk -F'\t'` and never with `read` — tab is IFS whitespace, so `IFS=$'\t' read` strips a leading tab and merges a run of them, and one empty field would shift every field after it, reading one login's windows as another's. That hazard is also why the writer puts `-` in every field a caller left empty.

**`resume-queue.tsv`** — 3 columns: session id, launch directory, title.

### What is persisted, and what is not

Three allowlists, all narrow on purpose, all pinned.

**The cache** is `jq -c '{rate_limits, context_window, model, version}'` of the statusline payload. The payload also carries `cwd`, `transcript_path`, `workspace.repo`, the prompt id and a dozen other fields — none of them read by anything, all of them durable on disk once written, so they are dropped rather than stored against a use nobody has. Measured on a live 17-key payload: 1,629 bytes in, a 482-byte cache out, about 70% smaller. Every reader was checked against the four keys — the overview, `--wait`, `--json` and the `account` list, between them reading `.rate_limits.*`, `.context_window.used_percentage` and `.model.display_name`/`.model.id`. `version` has one reader, `session doctor`. Case 20 asserts the four keys are present and names `cwd`, `transcript_path`, `workspace`, `session_id` and `cost` as absent.

**The snapshot** is `jq -c '{session_name}'`, which is all `session name` and the peer lookup ask for. Case 22 pins the key set exactly.

**The Fable file** is `{"fable":{"used_percentage":N,"resets_at":EPOCH}}` — the usage endpoint's one Fable row, with its ISO reset converted to epoch seconds. A response without such a row writes nothing. The rest of the response (spend, credit balances, the other meters) is dropped. Case 14 `[fable]` pins the exact bytes.

All three are written through a temp file in the same directory and `mv -f`, so a reader never sees a half-written file — and the temp name carries the writer's pid, because every render of one login writes the same cache and renders overlap. Under a shared name the second writer's `>` truncates the first's temp, the shorter write lands over the longer, and the longer one's tail survives as trailing garbage: a complete JSON line, then a stray `"}`, which every reader of that login's cache then fails to parse until a render on that login rewrites it — for a non-live login, until you switch back. Case 20 pins that a malformed payload leaves the previous cache byte-identical; the overlapping-renders case forces two writes of one login to overlap through a jq shim and pins that the cache and the snapshot both come out whole.

### `time --json` — the contract a task logger reads

```json
{"sid":"…","date":"2026-08-31","day":"today","turns":0,"active_s":0,"longest_s":0,
 "unclosed":0,"open_turn_s":0,"failed":0,"prompts":0,"subagents":0,"waits_s":0,
 "attended_s":0,"attended_basis":"active","watched_s":0,"ended":0}
```

Four fields are the contract: `date` is a `%F` string, `attended_s` and `active_s` are integers, and **`attended_basis` is `focus` or `active`**. Nothing else is promised, and the rest of the object may change — `day`, for instance, is `today`, `yesterday` or the `%F` date of the audited day, and nothing reads it. `session doctor` check 5 asserts all four by running the command. A consumer should be laxer than the contract — require only `date` and `attended_s`, default `active_s` to 0 and an absent `attended_basis` to `focus` — so a build predating either field still books rather than refusing. Zeros rather than an error when nothing is logged yet, so a caller can always take a delta — but the command still **exits 1 while the turn log has no rows at all**, which is the "measurement was never on offer" state described above.

`attended_basis` is decided by one thing: whether the **live** focus log has any content. With focus rows, `attended_s` is focused-tab time, idle-capped at `SESSION_ATTEND_GRACE`. Without them there is no attended measurement at all, and rather than hand a consumer a zero (which reads as "you were not there") or an unlabelled substitute, the basis says `active` and `attended_s` equals `active_s`, the turn span. A task logger should book an `active`-basis figure through an estimate token — `~11m`, never `11m04s` — because it is an upper bound on attention rather than a measurement of it, so that a reader can partition the corpus on the `~` before calibrating anything from it.

One state to know about: on a machine that once had focus tracking and has had no focus rows for longer than the 8-day retention, the live file is empty and the basis reports `active`. That is the honest answer — the tmux hooks are not firing — but it is not a state most readers would predict. Case 6 pins the contract, case 7 the spans and the idle cap; the consumer's side of it, including that an absent `attended_basis` defaults to `focus`, is the consumer's own suite to pin.

### Reads inside the retention window

`session time` reads the live log alone when the requested day is inside the 7-day floor **and** the live file's first row is old enough to cover it; otherwise it reads the archive too. The second half is the proof rather than an optimisation: a live file that starts *after* the requested midnight cannot cover that day whatever the floor says. Measured on a real store, today's read skips 151k archive rows and takes ~1.6 s, against 3.5 s for `--date 2026-08-01`, which genuinely needs both halves. Case 8 pins all three arms.

## Focus tracking

Optional, and the installer will not wire it for you: a tmux config and a crontab are files a person owns and re-sources by hand, and a half-applied edit to either is worse than a line you paste yourself. It prints exactly these five lines at the end of a run, with the absolute path to your linked CLI wherever `session` appears below:

```
set-hook -g "client-focus-in[0]"        "run-shell -b 'session --focus-mark in  #{hook_client}'"
set-hook -g "client-focus-out[0]"       "run-shell -b 'session --focus-mark out #{hook_client}'"
set-hook -g "client-detached[0]"        "run-shell -b 'session --focus-mark out #{hook_client}'"
set-hook -g "session-window-changed[0]" "run-shell -b 'session --focus-mark switch #{hook_session_name}'"

* * * * * session --focus-mark tick
```

Then `tmux source-file ~/.tmux.conf`. Without them everything still works and says so through `attended_basis`.

The cron tick logs an activity mark for every client with input in the last ~90 s, focused or not, stamped with the client's **actual** input time rather than tick time. Typing and scrolling both count, since tmux mouse mode makes wheel events input. Attention then stops accruing `SESSION_ATTEND_GRACE` seconds after the last interaction, so a tab left focused on an empty desk does not count. Case 16 pins the 90-second recency filter and the activity stamp; case 7 pins the grace.

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
| `5H`, `RESET` | the 5-hour window's used % and time to its reset; `~0%` and `?` once that reset has passed |
| `WEEK`, `RESET` | the all-models weekly window's used % and time to its reset; `~0%` and a `~` countdown once it has passed |
| `FABLE` | Fable's weekly cap, used %; `~0%` once its reset has passed. It resets with `WEEK`, so it has no countdown column |
| `AGE` | the age of the row's oldest figure: `now` under two minutes, then `Nm`, `Nh`, `Nd` |

`n/a` is a window the source did not carry. `-` is no data at all: `5H` and `WEEK` come from the statusline cache, which a login gets only once a session has rendered on it.

**`FABLE` is Fable's own weekly cap**, which the statusline cannot record: the payload carries only the 5-hour and all-models weekly windows (checked on Claude Code 2.1.273). Its source is `GET https://api.anthropic.com/api/oauth/usage`, the endpoint behind `/usage`, whose `limits[]` lists it as a `weekly_scoped` row with `scope.model.display_name` `Fable`. The endpoint is undocumented. `list` and `use` fetch it for every vaulted login whose `claudeAiOauth.expiresAt` is more than a minute away, in parallel, 5 s each, with that login's own access token passed to curl on stdin (`-K -`), never in argv. `use` fetches after the swap, never before it.

- **A lapsed token is not sent and not refreshed.** Refreshing rotates credentials the live login's sessions may hold. The login's last fetch is listed instead, and `AGE` shows how old it is when it is the row's oldest figure.
- **Anything short of a Fable row with a numeric percent keeps the previous file.** That covers curl failing, an HTTP error, a 200 whose body has no `limits[]` (the endpoint's in-band error shape), and a well-formed `limits[]` with no usable Fable row. The endpoint is undocumented, so a missing row is not treated as evidence that the figure went away.
- **`n/a` in `FABLE`** means no fetch has ever succeeded for that login.

Case 14 `[fable]` pins all of it against a curl stub, including the column layout, that the token never appears in curl's argv, and that a missing curl still lists every cached figure.

**A login is named by its email, and a seat in a Team or Enterprise organisation by `<email>+<org slug>`** (`me@example.com+example-org`). One email can hold a personal Max plan and a Team seat at once, with separate credentials and separate rate-limit windows; keyed by email alone, `/login` into the seat overwrote the plan's vault entry and both logins' windows landed in one cache (2026-09-15). The name is computed in one place, `session_login_read` in the lib, from `oauthAccount`'s `emailAddress`, `organizationType` and `organizationName`: a consumer organisation (`claude_max`, `claude_pro`, `claude_free`, or none recorded) keeps the bare email, so every entry vaulted before the rule kept its name. The vault file, the statusline cache and the session log's account column all carry that name; each entry also records the raw `email`. `use` takes a row number, the whole name (which always wins, because the bare email is a prefix of its own seat's name and no substring could otherwise pick the plan) or a unique case-insensitive substring; the list is numbered in C-collated name order so a number keeps meaning the same login until an entry is added or removed. Case 14 pins all of it.

**A vault entry that cannot authenticate is never installed.** Before anything is vaulted or written, `use` refuses an entry whose `claudeAiOauth.accessToken` is empty, `null` or absent, naming the login and pointing at `/login` — the remedy is a fresh login, not a retry. Nothing moves: the live credentials and the identity file are left exactly as they were.

**The swap is read back before `use` reports it.** After writing, the installed `claudeAiOauth` is compared with the vault entry's, out of `.credentials.json` rather than out of `.claude.json` — the identity file is a head start for the next statusline render, not the source of truth, and a concurrent session can rewrite it from memory. A mismatch exits 1 with a message naming the file, and neither the confirmation nor the table is printed; the Fable refetch does not run. The comparison is a boolean, so no token value is ever rendered. **`.claude.json` is written before the check**, so after a mismatch it names the login whose credential did not land — `session account list` marks that login `live` until a swap succeeds.

**This is the one platform-bound feature.** It swaps `claudeAiOauth` and `oauthAccount` inside `<config dir>/.credentials.json`, which is where Linux stores them. On macOS they are in the Keychain, the hot-swap property is unverified and probably absent, and building that branch needs a Mac. So on a config dir with no `.credentials.json`, `use` refuses naming the Keychain and pointing here, `save` exits 1 with "nothing to save", and **`session account` still lists the vault with each login's cached headroom**. All three are pinned by case 14 — but by *removing* `.credentials.json`, which simulates the macOS shape rather than testing it. Nothing here has run on a Mac.

The statusline's autosave calls `<clone>/session account save` whenever the live credentials are newer than the vault entry, and never when the login reads as `unknown` (case 24). It is `|| true`-guarded, so a `statusLine` pointing at a clone whose `session` has gone missing silently saves nothing — `session doctor` check 2 is what catches that.

**A live credential that carries no usable access token is never vaulted.** `save` exits 1, writes the reason to stderr and leaves the existing entry byte-identical. The test is `claudeAiOauth.accessToken` alone: a non-empty one vaults whatever else the object holds, `expiresAt` included; an empty, absent or `null` one is refused, whether `expiresAt` reads 0, is absent, or the other six keys are perfectly well-formed — the shape recorded five times in two months, which on 2026-09-15 went live and left nothing on the machine able to authenticate for 10.5 hours. While the live token is blank, `session doctor` prints a `credentials` FAIL: it names the vault entry to restore with `session account use <login>` when that entry carries a token of its own, and otherwise says no vaulted copy does — entries blanked before this refusal existed are still in vaults, and `use` installs whatever the entry holds.

## Reboot and resume

`session reboot` snapshots every live interactive session to the resume queue and reboots (`sudo systemctl reboot`, or `sudo shutdown -r now` where there is no systemctl); `session resume` reopens one tmux window per snapshotted session and clears the queue. `--scan [HOURS]` is the recovery path when no snapshot was taken, reading the transcript store instead. `-n` prints without doing anything.

Both **refuse with a message naming tmux** when tmux is absent (case 15). `session peers`, by contrast, works without it: it reads Claude Code's presence registry and prints the pane id the registry recorded, so a guard there would refuse a verb that works on any machine. That asymmetry — `peers` works, `reboot`/`resume` refuse loudly, `--focus-mark` is a silent no-op — is deliberate and worth knowing rather than discovering.

`SESSION_TMUX_MAIN_GUARD`, when set to an executable, runs before `resume` opens windows: a host's own pre-resume check. Running `session resume` automatically at boot needs a service unit, which is the host's business and not this installer's.

## Auto-resume: `--rewake-waiter` and the ⚠ advisory

Two `asyncRewake` entries, on `UserPromptSubmit` and `StopFailure`, armed by default. Once a window crosses `USAGE_WARN_PCT` (default 90) — or a turn dies on a cap — the entry becomes a waiter that wakes the session when the window resets or the login switches. **Its exit 2 is the wake signal**, delivered through the task-notification channel. `--no-rewake` opts out; `uninstall.sh` removes them.

**The version gate fails closed.** The pair is armed only when `claude --version` reports at least 2.1.233, the build the backgrounding behaviour was verified against, compared as dot-separated integer tuples rather than as strings (`2.1.99` is older than `2.1.233`, which a string comparison gets backwards; case 26 uses exactly that fixture). Below it, and **when there is no `claude` on `PATH` at all**, the pair is refused with a remedy rather than armed blind — a harness that does not background an async hook would run the waiter synchronously on every over-threshold prompt, blocking it there until the window reset. The lifecycle entries still land in every refusal case. A teammate installing from a shell where `claude` is not on `PATH` will hit this; the remedy is to fix `PATH` or pass `--no-rewake`.

**`timeout` is not enforced on an async entry, so the pair's `700000` is inert.** The field bounds a synchronous hook command; an `asyncRewake` entry is backgrounded and runs to completion regardless, which is the whole point of the mode. The value also carries a unit slip — `timeout` is seconds, as the lifecycle entries' `2` shows, so `700000` is eight days rather than the 700 seconds that was meant. It is left exactly as it is, deliberately: it changes no behaviour either way, moving it would rewrite every installed `settings.json` and break the assertion case 26 makes on it, and it is the right defence to already have in place should enforcement ever arrive. What follows from this is the rule that matters — **anything in the waiter that can block is bounded inside the script**, by its own sleep arithmetic and its own guards, because nothing outside it will do that.

**`rewakeMessage` and `rewakeSummary` are undocumented-but-observed fields.** They are embedded as literals in `install.sh` and match what live entries carried when they were observed. Re-verify them after a Claude Code upgrade.

**The advisory text is a human-review item.** At or above the threshold, `session --hook` injects one advisory — identical for every window and reset distance, only the lead sentence naming which window crossed — telling the model that a cap is not a reason to stop, wind down or hold back parallel work, because a waiter is armed. It is a paragraph of instruction to a model, written once and living at the `line=` assignment in `session`; read it when the auto-resume behaviour changes, because nothing tests its content. What *is* tested (case 5) is that the sentence claiming an armed waiter appears **only** when `settings.json` actually carries a `rewake-waiter` entry with `asyncRewake: true`. The probe is structural (`jq -e`), not a grep for the string: promising an armed waiter on the strength of a malformed entry is worse than promising nothing, because that entry never wakes anyone.

**Which reset the waiter sleeps to, when a cap death is all it has to go on.** Neither generic window warned means the cache cannot say which cap killed the turn, so the target is chosen in three steps. The live login's Fable weekly window comes first: if `fable.<login>.json` puts it at or above `USAGE_WARN_PCT` with its reset more than a minute out, that reset is the target and the wake-up names the Fable window. Otherwise whichever generic reset is still ahead — the 5-hour one first, the weekly otherwise. No future reset anywhere and the waiter does not arm at all.

The Fable step is there because that window gates only Fable and no generic reset lifts it: a waiter armed on the 5-hour reset after a Fable cap wakes, retries and dies again. Its reach is bounded by where the figure comes from. Only `session account list` and `session account use` write that file — the statusline's autosave does not — so the retarget fires only when `session account` has been run recently enough for the live login's figure to already read as spent. A stale *low* figure suppresses it and the waiter behaves exactly as it would with no file at all; a stale *high* one is still true, because Fable rises only while its login is live and otherwise resets weekly. Nothing is fetched here deliberately: a slow endpoint must never stand between a capped session and its wake. What remains is the weekly fall-through — a `rate_limit` death with a stale 5-hour reset and no spent Fable window genuinely can be the weekly cap, and sleeping to a reset up to seven days out is the one path where the waiter can outlive its usefulness by days.

## Platform support

The CLI, the statusline and the suite are bash 3.2 clean and free of GNU-only tools outside a named fallback, because macOS ships bash 3.2, BSD `date`, BSD `stat`, no `/proc` and no `flock(1)`. Case 1 greps every shipped script for the bash 4/5 constructs no syntax check can see, and case 13 for host names and hardcoded home paths.

- **Dates.** All day-boundary maths goes through perl `POSIX::mktime`/`strftime` rather than `date -d`. `mktime` with `isdst=-1` picks the offset in force on that local day, which is why a 23-hour or 25-hour DST day comes out right and why the next day's midnight is not midnight plus 86,400. Case 11 compares against GNU `date` over 44 dates in `Europe/Zurich`, `America/New_York` and `Australia/Lord_Howe`. It also covers a case GNU `date` gets *wrong by refusing*: on a zone whose DST transition is at midnight, local midnight does not exist on that day, `date` errors, and `epoch_of` still answers. Which way it normalises is the libc's call — glibc shifts forward, musl back — so on a musl host `session time --date <that day>` starts the day an hour early in those zones. Not worth machinery; recorded so nobody rediscovers it as a bug.
- **`--date` accepts** `YYYY-MM-DD` and `yesterday`. Free text (`3 days ago`) is a GNU `date` extension: it is passed through where GNU `date` exists and **refused with the list of accepted shapes** where it does not, rather than answered with a wrong day. The probe for "is this GNU date" asks it to parse a relative expression, not just to accept `-d`, because busybox `date` takes `-d @0` happily and then parses nothing relative.
- **`session time` refuses an unresolvable day** rather than reporting one. Without perl the boundary comes back empty, awk reads it as epoch 0, and the whole log reports as today — measured on a host with perl removed, a 2001 turn-log row came back as today's work with an open turn of 218,940 hours. Two cases pin the refusal.
- **Process inspection** reads `/proc` where it exists and falls back to `ps`. `proc_ppid` and `proc_cmdline` run natively on both paths and are tested on both. **`proc_env`'s fallback is `ps -Eww -o command=`, which is Darwin-only and has never executed anywhere**: Linux procps rejects `-E` and busybox `ps` takes none of the flags, so its case prints `skip` in every leg. On a Mac where that read cannot see the ancestor, `session whoami` degrades to a clean refusal when `CLAUDE_CODE_SESSION_ID` is absent.
- **Locking** uses `flock(1)` where it exists and perl `flock` otherwise. The perl path sets `$^F=10`, which is load-bearing: perl sets `FD_CLOEXEC` on descriptors above `$^F` (default 2), so without it the lock is dropped by the `exec` and there is no mutual exclusion at all — a failure that looks exactly like success. Case 12 pins it by showing the second caller exit 75 while the lock is held. Busy is 75 wherever the backend can say so; busybox `flock` has no `-E` and exits 1, and callers treat any non-zero as "skip".
- **`stat`** goes through `mtime_of`, which tries `stat -c %Y` then BSD `stat -f %m`. The BSD branch, like `ps -Eww`, has not run on a real Mac.
- **`curl` is optional**, used only by `session account` to fetch the `FABLE` column. Without it every login lists its last fetched figure, or `n/a`.
- **The statusline hard-requires `jq`** — it is a jq program with a shell around it. Its whole suite skips without one, which is why the stock `bash:3.2` image proves nothing about it and the enriched image is the leg that matters.

## Tests

```
bash tests/run.sh
```

Three suites, run natively and then under `docker run bash:3.2` when docker is present — the closest thing here to macOS's `/bin/bash`, and what catches a bash-4-only construct the host's bash 5 accepts silently. The runner prints per-suite counts for both legs and exits non-zero if any run fails. `--require-3.2` turns a skipped container leg into a failure — the flag for an acceptance run, since without it a machine with no docker image passes having tested one shell — and `SESSION_TEST_IMAGE=session-tests:bash3.2` selects the enriched image whose recipe the runner's header carries (the header deliberately carries no case counts: a count in a comment is a measurement nothing recomputes); the stock `bash:3.2` image is Alpine with no perl, no jq, no timezone database, no GNU date and no GNU find, so a large share of cases skip there with their reason printed.

That skipping is not caution, it is the alternative to a green run that proves nothing: busybox `date` accepts `-d @0` and parses no relative expression, and an image without tzdata reports every zone as UTC — a date comparison there would be two identical mistakes agreeing. The suite probes its oracle rather than trusting it.

## Removal

```
uninstall.sh [--bindir DIR] [--name NAME]
```

Removes every hook entry of this CLI's shape, the `statusLine` when it is ours, and the symlink when the name resolves to this clone. A foreign `statusLine`, a symlink pointing elsewhere and every other setting are left exactly as they are; running it twice changes nothing the second time (case 29). It checks whatever `name` currently resolves to on `PATH` as well as `--bindir`, so an install into a directory nobody remembers is still found.

Two deliberate exceptions, both printed: **the data root stays** (it is your recorded history, and the `rm -rf` line is printed rather than run), and **`session.conf` stays** — it describes the machine, not the install, and a reinstall on that machine wants it. Hook removal is by ownership pattern alone, so it also clears another clone's entries; the statusLine and the symlink are removed only when they are ours. The output names the count either way.

## Cutting over from a deployed copy

A machine that ran an earlier copy of this CLI deployed out of its own config repository (`<config dir>/scripts/session.sh` and `hooks/statusline.sh`, wired by that repository's `settings.json`, tmux config and cron) cuts over to the clone: the config repository keeps the wiring and the data and stops shipping the code, so exactly one copy runs on the machine. `--data-dir` pointing at the existing store (recorded as `SESSION_DATA_DIR` in `session.conf`) keeps it in place — nothing moves, and `session peers`, the account vault and anything reading the logs keep working against it. A symlink at the name that points at the deployed copy is refused like any other foreign link and taken over with `--force-link`; the foreign `statusLine` is refused as any other would be, and merged by hand. That `chmod 700` on a data root that was 775 is deliberate.

Two things the merge will not do for you, both because the entries are not ours to delete. The old copy's hook entries point at a live file on a path that is neither ours nor dead, so **they survive the merge** — leave them and the machine runs two sets of hooks into one store, two rows per turn, until they are removed in the same edit. And the deployed files themselves must outlive the settings change: hook configuration loads at session start, so every session alive at cutover keeps calling the old paths, and deleting the files first turns each of those calls into a failure the `|| true` hides. Change the settings, then delete the files once nothing is still pointing at them.

One deliberate deletion came with the port, so the change is easy to find later: the legacy unkeyed `last-status.json` fallback and the environment override that named a cache file are gone. Caches are per-login now, with no unkeyed shape to fall back to, and `session --file PATH` covers reading a specific cache file. Existing full-payload `last-status.*.json` files need no migration: every reader takes only the four allowlisted keys, and the first render after cutover replaces one with the small shape.
