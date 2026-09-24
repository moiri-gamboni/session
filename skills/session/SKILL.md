---
name: session
description: The `session` CLI — this Claude Code session's id and title, the plan's 5-hour and weekly rate limits, per-session usage and time, subscription login switching, and reboot survival. Use when asked how close the limits are, when they reset, how full the context is, which session is using the budget, how long was spent, or what this session's id or name is; before or between waves of subagents in a big job; when a cap is spent and another login may have headroom; and to reboot the box or reopen sessions after a reboot.
---

# session — identity, limits and time for the invoking Claude Code session

`session` reports on the Claude Code session that runs it. `session --help` is the flag reference (each verb also takes `-h`), `README.md` in the clone is the ops contract (install, data files, how each figure is made), and `session doctor` checks an install and names what is wired wrong.

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

**5-hour** and **weekly** are the plan's caps, shared by every session, subagent and model on the login, so a fan-out that burns them blocks everything; **pace cap** is the used % `--guard` allows at this point in the window. **account** is the subscription login, shown only when this session's config dir is not the machine's primary one; every limit and share figure belongs to that login alone. **context** is this session's context-window fill, **share** its estimated slice of each cap.

| Command | Use |
|---|---|
| `session` | the overview above |
| `session whoami [--id\|--name]` | this session's id and title, correct across concurrent tmux panes; `agent <dir> -r "$(session whoami --id)"` resumes it |
| `session name <id-prefix>` · `session id <title-substring>` | another session's title from its id, or its id from its title |
| `session peers` | live sessions: the `ListAgents` name (`SendMessage`'s `to:`) beside id, title and git branch, so `session peers \| grep <branch>` finds the session that owns a branch or worktree. REACH `no` = registered but invisible to `ListAgents`; restart that session |
| `session usage [--all]` | counted `$` burn and estimated share of each cap, for this session or every one |
| `session time [--all] [--yesterday]` | turns, active, attended and watched time |
| `session account` · `session account use <row>` | saved logins with their headroom; switch login |
| `session reboot` · `session resume` | reboot without losing the sessions; reopen them |
| `session --guard` · `session --wait guard` | pacing gate for a fan-out |

## Pacing a fan-out

Run `session --guard` before each wave and inside each agent: exit 0 is go, exit 3 is pause and names the window. By default a window pauses once its used % runs ahead of the elapsed fraction of the window; `FIVE_GUARD`/`WEEK_GUARD` pick another curve per window (`--help`). When it pauses, `session --wait guard` in the background (Bash `run_in_background`) sleeps until the guard would pass, and its exit is the wake-up.

## When a cap is near or hit

**A cap is never a reason to stop, wind down or hold back parallel work.** The install arms a background waiter (the `session --rewake-waiter` hook entries) once a window passes `USAGE_WARN_PCT` (default 90) or a turn dies on a cap; it wakes the session, even an idle one, when the window resets or the login switches. The worst case is a pause that ends by itself. The per-turn hook is silent below the threshold, so no ⚠ in context means usage is under it; above it, the ⚠ advisory says what this section says.

A reset time quoted in a usage-limit error, this session's or a subagent's, belongs to the current login: a login switch lifts the cap at once, so the time is never a deadline or a planning constraint.

**A cap or authentication death may also switch the login by itself** (`session account auto`, run by the same hook) when a saved login serves more than the live one. A wake-up saying the login switched may be that automatic decision, not a person: treat it as the cap lifted and carry on. If it says the new login serves every model except Fable, work that died on a Fable cap must continue on another model; a resumed subagent keeps the model it died on and would hit the same cap again.

## Switching logins — `session account`

When a cap is spent and another subscription is saved, `session account` lists every login with its 5-hour, weekly and Fable used % and resets, and `session account use <row number | name | unique substring>` switches. The switch is box-wide, since every `claude` here shares the config dir, and lands on each running session's next request: no restart, no re-authentication, transcripts and `--resume` unaffected. Displayed %s lag one turn behind it. To add a login, run `/login`; the login it replaces is already saved, so `use` brings it back.

`FABLE` is Fable's own weekly cap: a login can have weekly headroom and still be out of Fable, so pick one with Fable headroom when the work needs Fable. `session account -h` explains `~0%`, `?`, `AGE` and seat names (`<email>+<org>`).

`session account auto --dry-run` shows what the automatic decision would do; `SESSION_AUTO_SWITCH=off` in `<config dir>/session.conf` turns it off (`session account -h`).

## Per-session usage — `session usage`

`$` figures are counted from statusline samples. The estimated % splits each window's observed movement by tracked `$` share, so it is an upper bound when headless `claude -p` runs or usage off this box also burn the login. `≈0.0%` right after a reset and `n/a` (no basis yet) are normal. A subagent's burn counts in its parent session.

## Time — `session time`

**active** is the sum of turn spans, start to end, tool time included and the gaps between turns excluded. **attended** is time the session's tmux tab was focused, stopping `SESSION_ATTEND_TAIL` seconds after the last keypress or scroll (default: `SESSION_ATTEND_GRACE`, 600). **watched** is their overlap. An interrupted turn can lack its end and shows as *unclosed*, adding nothing, so active is a floor.

`session time --json` is what a task logger books worklog time against, reading `date`, `attended_s`, `active_s` and `attended_basis`. `attended_basis: active` means this machine has no focus tracking and `attended_s` is just `active_s`, an upper bound on attention: book it as an estimate (`~11m`), never as `11m04s`. The contract is README.md's "`time --json`" section; `session doctor` says which basis this machine is on.

## Surviving a reboot — `session reboot` + `session resume`

A reboot kills every session, and Claude Code prunes its record of running sessions at startup, so capture them first: `session reboot` snapshots every live interactive session, then reboots (`-n` prints the snapshot without rebooting; `-y` is required without a terminal, as in a Bash tool call). `session resume` reopens one tmux window per snapshotted session in its launch directory; a boot unit may run it for you. With no snapshot, `session resume --scan [HOURS]` reopens every session with transcript activity in the last HOURS (default 48). Both need tmux.

## Reading the numbers

- Limit figures come only from the statusline. `no cache yet` means it has not rendered on this login yet; interact twice, since a session's first render writes nothing.
- Limits refresh only on an API response, so an idle or capped session shows the last window it heard about, and a passed reset shows `?`. The built-in `/usage` fetches live and settles a disagreement.
