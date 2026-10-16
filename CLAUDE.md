# CLAUDE.md

`session` is one bash CLI (`session`), its status line (`statusline.sh`), an installer (`install.sh`, `uninstall.sh`), and a plugin carrying a skill (`skills/session/SKILL.md`) and a hooks module (`hooks/reload-on-switch.ts`). README.md is the contract for users and anything that reads the CLI's output; this file is for changing the code.

## Commands

```
bash tests/run.sh                  # every suite
bash tests/session.test.sh         # one suite
claude plugin test .               # the hooks module's tests alone (hooks/*.test.ts)
```

## Tests

- **Branches that have never run:** `proc_env`'s `ps -Eww` fallback (Darwin-only; its case always skips), `mtime_of`'s BSD `stat -f %m`, and the macOS Keychain shape of `session account`, which the suite simulates by removing `.credentials.json` rather than testing it.
- **The hooks module's tests run on Claude Code's engine**, not in bash: `tests/plugin.test.sh` wraps `claude plugin validate` and `claude plugin test` and skips without `claude` on `PATH`. Types are not in the repo: Claude Code lays them in `.claude-plugin/types/` when it loads the clone with `--plugin-dir`, and its plugin-authoring skill's `types/claude-code.d.ts` carries the `tsconfig.json` to check against.
- **The compaction hold's assumptions about Claude Code and tmux were observed by hand on 2.1.301** and are listed in the comments above `--post-tool-batch` and `--compact-gate` in `session`; the suite covers the decisions against stubs only (its stdin is a pipe, Claude Code's a socket, which case 28 reproduces). Re-check them after a Claude Code update that touches compaction or hooks; the end-to-end run needs a tmux client attached under a pty that types.
- **The README cites no test cases.** To find the test behind a promise, grep the suites for the behaviour.
- **Nothing tests the ⚠ advisory's wording.** It lives at the `line=` assignment in `session`; reread it whenever auto-resume behaviour changes. The suite checks only that the sentence promising an armed waiter appears when, and only when, `settings.json` carries a `rewake-waiter` entry with `asyncRewake: true`.
- **Sourcing `lib/common.sh` rebinds `SESSION_DATA`** from `SESSION_DATA_DIR`, `session.conf` and the defaults, so a scratch script that sets `SESSION_DATA` and then removes it deletes the machine's real data root. Clean up scratch by a literal path, never by that variable.

## Conventions

- **The hooks module runs in Claude Code's plugin engine**: TypeScript with no Node and no DOM, reaching files, timers and commands only through `$`. Its API is early access and moves between releases, so keep it to the few calls it makes. `tests/plugin.test.sh` catches API drift only, against a mocked engine; what the module relies on (claude.ai connectors move to the new login's ids on `/reload-plugins`) is checked by hand, by switching logins under a live session and calling a connector.
- **bash 3.2 clean, no GNU-only tool without a fallback.** macOS ships bash 3.2, BSD `date`/`stat`, no `/proc` and no `flock(1)`. Dates go through perl, `stat` through `mtime_of`, processes through `/proc` with a `ps` fallback, locks through `flock(1)` with a perl fallback; the comment at each fallback says why it is shaped the way it is. README "Platform support" states only what a user sees. Case 1 greps shipped scripts for bash 4/5 constructs that a syntax check misses.
- **Public repo.** Case 13 greps for host names and hardcoded home paths; no personal, employer or machine names anywhere in the tree or in commit messages (a pre-push hook on the clone refuses them).
- **Mechanism lives in comments at the writer.** The README states the contract (commands, config, data files, schemas, the `time --json` fields a task logger reads); why a code path is shaped the way it is goes in a comment beside it. Change the README only when the contract changes, and keep the headings other tools cite (the skill and `--help` point at "`time --json` — the contract a task logger reads").
- **Help, skill, README.** A new flag goes in `session --help` (or the verb's `-h`); the skill gets a line only if a session would otherwise use the tool wrongly.
