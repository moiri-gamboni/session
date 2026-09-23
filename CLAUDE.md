# CLAUDE.md

`session` is one bash CLI (`session`), its status line (`statusline.sh`), an installer (`install.sh`, `uninstall.sh`) and a skill (`skills/session/SKILL.md`). README.md is the contract for users and anything that reads the CLI's output; this file is for changing the code.

## Commands

```
bash tests/run.sh                  # every suite, natively and under docker bash:3.2
bash tests/run.sh --require-3.2    # acceptance: a skipped 3.2 leg fails the run
bash tests/session.test.sh         # one suite, this machine's bash only
```

The enriched test image (`SESSION_TEST_IMAGE=session-tests:bash3.2`) and what the stock image skips are in `tests/run.sh`'s header.

## Conventions

- **bash 3.2 clean, no GNU-only tool without a fallback.** macOS ships bash 3.2, BSD `date`/`stat`, no `/proc` and no `flock(1)`. Dates go through perl, `stat` through `mtime_of`, processes through `/proc` with a `ps` fallback, locks through `flock(1)` with a perl fallback (README "Platform support" says why each fallback is shaped the way it is). Case 1 greps shipped scripts for bash 4/5 constructs that a syntax check misses.
- **Public repo.** Case 13 greps for host names and hardcoded home paths; no personal, employer or machine names anywhere in the tree or in commit messages (a pre-push hook on the clone refuses them).
- **Mechanism lives in comments at the writer.** The README states the contract (commands, config, data files, schemas, the `time --json` fields a task logger reads); why a code path is shaped the way it is goes in a comment beside it. Change the README only when the contract changes, and keep the headings other tools cite (the skill and `--help` point at "`time --json` — the contract a task logger reads").
- **Help, skill, README.** A new flag goes in `session --help` (or the verb's `-h`); the skill gets a line only if a session would otherwise use the tool wrongly.
