---
name: session
description: The session CLI — this Claude Code session's identity and its usage of the plan's rate limits. Run `session` for the overview (id · name, the 5-hour and weekly rate-limit %s + reset times that actually gate the session, context fill, this session's share); `session whoami` for the id/title (pane-safe, e.g. to build a `claude --resume <id>` command or label output); `session usage [--all]` for per-session burn attribution; `session time` for per-turn and attended time; `session --guard` as a pacing gate for multi-agent fan-outs. Use when the user asks "how close are we to the limit", "how much is left", "when does it reset", "how full is the context", "how much has this/each session used", "which session is eating the budget", "how long did I spend on this", or "what's my session id / name"; for "reboot the box" / "get my sessions back after a reboot", which are `session reboot` and `session resume`; when a subscription cap is spent and another login is available (`session account`); and mid-task before or between waves of a big job to decide whether to keep spawning subagents. A per-turn hook (`session --hook`, transcript-suppressed) stays silent below `USAGE_WARN_PCT` (default 90) and injects the usage line + a ⚠ advisory only once a window crosses it — so absent a ⚠, usage is under 90%; run `session` when the actual numbers are needed.
---

# session — identity, limits and time for the invoking Claude Code session

One command, session-scoped, installed from a clone (`install.sh`; `session doctor` checks an install end to end and names what is wired wrong — `README.md` is the ops contract for both). Example overview:

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

**5-hour** and **weekly** are the account-global caps that throttle the plan — shared across every session, agent and model, so burning either fast in a fan-out blocks everything. **account** is the subscription login this session runs under: limits and attribution are keyed by it, so every figure belongs to that login only, and sessions on another login neither gate nor get counted against this one. It is shown only when this session's config dir is not the machine's primary one. **context** is this session's context-window fill. **share** is this session's estimated slice of each cap.

| Command | Purpose |
|---|---|
| `session` | the overview above |
| `session whoami [--id\|--name\|--json]` | identity only: id + auto-title. Pane-safe (`$CLAUDE_CODE_SESSION_ID` plus an ancestor walk), so it reports the session actually invoking it, correct across concurrent tmux panes. Resume pointer: `agent <dir> -r "$(session whoami --id)"` |
| `session name <id\|prefix>` · `session id <title-substring>` | cross-session lookup both directions: a title from an id (the 8-char ids in tables and briefs work as prefixes), or an id from a case-insensitive title substring. One match prints the bare value (scriptable); several print `id<TAB>name` lines. Sessions active in the last 8 days resolve instantly; older ones fall back to the transcript store (id→name stays fast, title queries there grep GBs, ~10 s) |
| `session peers [--json]` | live Claude Code sessions on this box, one row each: the cross-session address (the NAME `ListAgents` shows = `SendMessage`'s `to:`) mapped to session id and title, with REACH = whether its messaging socket is live. REACH `no` means registered but invisible to `ListAgents` — restart that session. `--json` carries full session ids |
| `session usage [ID] [--json]` | one session's counted $ burn and estimated share of each window (default: the invoking session) |
| `session usage --all [--json]` | every tracked session, sorted by 5h spend, `←this` marking the caller |
| `session time [--all] [--yesterday] [--date D] [--spans] [--json]` | per-turn time: closed turns, active, watched (active ∩ attended), attended, waits, open/unclosed |
| `session account [use <name>\|save\|rm <name>]` | several subscription logins in one config dir (see below) |
| `session reboot [-n] [-y]` | snapshot every live interactive session, then reboot the box; the sessions reopen at boot where a boot unit runs `session resume`. `-n` writes and prints the snapshot without rebooting, `-y` skips the confirmation (required when stdin is not a terminal) |
| `session resume [--scan [HOURS]] [-n]` | reopen the snapshotted sessions as tmux windows, one each, then clear the snapshot. `--scan [H]` ignores the snapshot and takes every top-level session with transcript activity in the last H hours (default 48). `-n` prints without opening. Sessions already running are skipped |
| `session --compact` | one frugal line: date/time + 5h and weekly %s; always exits 0 |
| `session --guard` | pacing gate: exit 0 = OK, exit 3 = PAUSE (prints which window tripped) |
| `session --wait [5h\|week\|guard]` | block until that window resets, or until `--guard` would pass; then exit 0 |
| `session --json` · `session --file PATH` | raw overview fields; read a specific cache file |
| `session doctor` | check this install end to end; `ok`/`pending`/`FAIL`, only a FAIL exits 1 |

Exit codes: 0 success (plumbing modes unconditionally), 1 no data yet or not inside a session or a failed `doctor` check, 2 bad arguments, 3 PAUSE.

## Pacing a fan-out — `session --guard`

Run it before each wave, and inside each agent. Configure each window independently through `FIVE_GUARD` / `WEEK_GUARD`: `linear` (default — pause if used% > 100·x, where x is the elapsed fraction of the window), `sqrt` (permissive early, tightens late), `pow:P`, a flat `<int>` percent, or `off`. Invalid specs exit 2. Window sizes come from `FIVE_WINDOW` / `WEEK_WINDOW` (seconds).

```
WEEK_GUARD=sqrt FIVE_GUARD=linear session --guard   # weekly eased, 5h linear
session --guard || session --wait guard             # blocked? wait for the pace
                                                    # line to clear (no polling)
```

`--wait guard` is not a poll: it computes the earliest time the rising pace cap can reach the current used%, sleeps exactly to it, re-checks against a fresh cache, repeats.

## Auto-resume after a cap — `--rewake-waiter` and the ⚠ advisory

Auto-resume is armed by the harness, not by the model: two `asyncRewake` hook entries (`session --rewake-waiter`, on `UserPromptSubmit` and `StopFailure`) background themselves and, once a window crosses `USAGE_WARN_PCT` (default 90) or a turn dies on a cap, become a waiter that wakes the session — even from idle — when the window resets or the login switches. Its exit 2 delivers the message through the task-notification channel.

**So a cap is never a reason to stop, wind down or hold back parallel work.** Worst case is a pause the armed waiter rides out, and the ⚠ advisory the per-turn hook injects at the threshold says exactly that: one message even when both windows warn, identical whatever the window or reset distance, with only the lead sentence naming which crossed. A quoted reset time in a usage-limit error is scoped to the current login, so a login switch lifts the cap immediately and the time is never a deadline or a planning constraint. Manual `session --wait 5h|week|guard` in the background (Bash `run_in_background`) still works for explicit pacing, and also exits within 5 minutes of a mid-wait login switch. Once a warned window's reset passes — or the login switches to an account below the threshold — the hook injects a single one-line notice that work can continue.

The advisory's armed-waiter sentence appears only when the settings actually carry a `rewake-waiter` entry with `asyncRewake: true`, checked structurally rather than by matching the command string.

## Switching subscription logins — `session account`

When a cap is spent and another subscription is available, `session account` lists every saved login **with its rate-limit headroom and reset countdowns**, and `use` switches in place:

```
$ session account
         #  LOGIN                                    5H    RESET   WEEK  RESET    FABLE  AGE
         1  old@example.com                          ~0%   ?       ~0%   ~5d20h   ~0%    4d
  live   2  you@example.com                          34%   2h10m   97%   0h48m    100%   now
         3  you@example.com+acme-corp                0%    3h02m   12%   4d07h    83%    3h

$ session account use 3
Switched to you@example.com+acme-corp
         #  LOGIN                                    5H    RESET   WEEK  RESET    FABLE  AGE
  live   3  you@example.com+acme-corp                0%    3h02m   12%   4d07h    83%    3h
Takes effect on the next request — including the 4 session(s) already running,
which share this config dir. Their displayed %s catch up one turn later.
```

`use` takes a row number, the whole login name, or any unique substring of it. Rows are numbered in name order, so a number keeps meaning the same login until a login is added or removed. One config dir, swapped in place, so transcripts, memory, settings and MCP servers are unaffected and `--resume` still works. **A running session adopts the new login on its very next request** — no restart, no re-auth — so this works mid-task when a cap runs out. Two things follow: the switch is **box-wide**, since every `claude` there shares the config dir; and between requests the statusline only replays the last API response, so displayed %s lag by one turn even though the switch already happened.

**Adding a login is just `/login`** — there is no `add` subcommand and none is needed: the statusline vaults whatever you log into, within a render. `/login` is non-destructive here, because the login it replaces was vaulted while it was live, so `session account use <old>` restores it without re-authenticating.

**Names.** A login is named by its email; a seat in a Team or Enterprise organisation is `<email>+<org slug>` (`me@example.com+example-org`), because one email can hold a personal plan and a seat with separate credentials and separate limits. The plan's name is a prefix of the seat's, so no substring picks the plan: `use me@example` is ambiguous and says so, `use +example` picks the seat, and the plan is its row number or its whole name.

**`FABLE` is Fable's own weekly cap**, separate from `WEEK`: a login can have weekly headroom and still be out of Fable. At that cap Claude Code asks whether to continue on usage credits or switch to another model (seen in the 2.1.273 build). It resets with `WEEK`, so it has no countdown of its own. The statusline never sees it, so `list` and `use` fetch it from the usage endpoint behind `/usage`, with each login's own token while that token is unexpired. A login whose token lapsed shows its last fetch. `n/a` means it was never fetched. Pick a login with Fable headroom when the work needs Fable.

`AGE` is how old the row's oldest figure is, and `-` means no data at all. A non-live login's figures stop refreshing when you switch away, so its resets go stale asymmetrically. The weekly runs on a fixed 7-day cadence, so a passed weekly reset is projected forward with a `~` countdown. The 5-hour window is usage-anchored, opening on that account's first request after an idle gap, so a passed 5-hour reset prints `?`. Either way a passed reset shows `~0%`: usage dropped to zero at the boundary, and anything used since then is invisible until that login renders again.

**Platform:** the swap is verified on Linux, where the credentials live in `<config dir>/.credentials.json`. On macOS they are in the Keychain, which this build cannot swap: `use` refuses naming that reason, `save` exits 1 with "nothing to save", and listing the vault still works. Those three behaviours are pinned by a test that simulates the macOS shape; none of them has run on a Mac.

## Per-session attribution — how the numbers are made

Counted where possible, estimated only at the last step.

1. The statusline logs each session's cumulative API-equivalent cost to the data root's `session-log.tsv` whenever it moves (~10 s while generating; a 10-minute idle heartbeat; an 8-day live window, older rows moved daily to an append-only `archive/` — history is never deleted). Each sample also records the dynamic payload fields — cumulative in/out tokens, context %, cache read/creation composition, lines added and removed, wall and API durations, model id, prompt id — so future views have history. Per-session **$ figures are counted** from in-window deltas.
2. The **est %** splits the global %-movement observed *while sampling was live* by tracked-$ share. Pre-coverage burn stays unattributed.

Caveats — est %s are upper bounds when these apply, while $ columns stay exact: headless `claude -p` runs render no statusline, and off-box usage (claude.ai, another device) is invisible; both inflate tracked shares. Cross-model splits assume limit weights track API prices. Right after a reset or a fresh deploy expect `≈0.0%` until the global % moves; `n/a` means no coverage basis yet. Subagent burn lands in the parent session, which is correct; tmux teammates are tracked individually.

## Per-turn and attended time — `session time`

Turn boundaries come from hooks, not from clocks in a payload: the `UserPromptSubmit` hook logs each turn's **start** and the `Stop`/`StopFailure` hooks log its **end** (`e`, or `f` with the API error type — `rate_limit` marks the exact moment a cap bit). Further events: session end, subagent spans paired by agent id, compactions, and mid-turn permission prompts shown as a `waits` line. Turn wall time is end minus start, so it includes tool execution, and gaps between turns are excluded by construction — neither figure is available from the payload, where `cost.total_duration_ms` is session wall clock ticking through idle and `total_api_duration_ms` excludes tool time. Hook-fed means headless `claude -p` runs are covered too.

On top of that, tmux client-focus hooks log focused-tab spans to a separate log, so `session time` also reports **attended** time: whether you were actually looking at the session, not just whether it was working. Attended is idle-capped — a once-a-minute cron tick records an activity mark for each client with recent input (typing and scrolling both count), and attention stops accruing `SESSION_ATTEND_GRACE` seconds (default 600) after the last interaction, so a tab left focused on an empty desk does not count.

**`session time --json` carries `attended_basis`, and it decides what `attended_s` means.** With focus rows in the live log it is `focus`: focused-tab time, idle-capped. Without them it is `active`, and `attended_s` equals `active_s`, the whole turn span — an upper bound on attention rather than a measurement of it. A task logger reads exactly this and should book an `active`-basis figure as `~11m` rather than `11m04s`, so a reader partitions a worklog on the `~` before calibrating anything from it. `session doctor` says which basis this machine is on.

Caveats: an interrupted turn may never get its end event and shows as *unclosed*, adding no time, so active is a floor; a trailing *open* turn shows its age; mid-turn queued messages fire extra turn starts and inflate *unclosed* slightly. `--date` accepts `YYYY-MM-DD` or `yesterday`; free text like "3 days ago" needs GNU `date` and is refused with the accepted shapes where there is none.

## Surviving a reboot — `session reboot` + `session resume`

A reboot destroys the tmux server and every Claude Code session in it. Claude Code's presence registry is pruned at startup, so the set of sessions that were running cannot be recovered afterwards — it has to be captured first.

```
$ session reboot -n
Snapshot -> <data root>/resume-queue.tsv

SESSION   DIRECTORY                        TITLE
e935fd2b  /home/you/code/server            Reboot from tmux
df8806e3  /home/you/code/website           Weekly report

2 session(s) will be restored after the reboot.
```

`session reboot` writes that snapshot and reboots; `session resume` reopens one tmux window per snapshotted session and clears the snapshot. Wiring `resume` to run at boot is a service unit the host owns, not part of the CLI. `session resume --scan [HOURS]` is the recovery path when no snapshot was taken: it reads the transcript store instead, so it also surfaces short-lived and deliberately closed sessions. Each session reopens in the directory it was launched in, recovered from its transcript's project-dir slug; `claude --resume <id>` resolves an id from any directory, so a session whose launch directory cannot be determined still reopens.

**These two need tmux and refuse with a message naming it when there is none.** `session peers` does not — it reads the presence registry and works on any machine.

## Caveats that change how you read the numbers

- **The 5h/weekly data exists only as statusline stdin fields**, never passed to hooks. The statusline persists each render's rate limits to a per-login cache in the data root, and `session` reads that. Without a statusline installed there are no limit figures at all, while `session time` still works.
- **Stale snapshots.** `rate_limits` only refresh on an API *response*, so a session that is idle — or rate-limited, which is exactly when you check — keeps reporting the window it last heard about. Readers take the freshest reading per window across sessions, since limits are account-wide. Once a `resets_at` has passed the % is marked `?` and no `0h00m` countdown is printed. `--guard` treats a stale window as unknown and will not pause on it. The built-in `/usage` fetches live, so it is the tiebreaker when the two disagree.
- **"no cache yet"** means the statusline has not rendered against this configuration; interact once. A session's *first* render deliberately writes no cache — it cannot yet know whose window it is looking at — so it takes two.
- **"no session log yet"** is the same, for the sample log.
- **Platform.** Linux and macOS both run everything except the account swap: dates go through perl rather than GNU `date`, process inspection falls back from `/proc` to `ps`, locking from `flock(1)` to perl `flock`, and the suite is verified under bash 3.2. Two fallback branches are macOS-only and have never executed anywhere — the `ps -Eww` environment read and BSD `stat -f` — so on a Mac, treat a `session whoami` that refuses cleanly as that branch failing rather than as a bug to chase. `session doctor`'s platform line says what this host has; `README.md` has the detail.
