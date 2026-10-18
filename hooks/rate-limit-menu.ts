import type { Register } from 'claude-code'

// Keep Claude Code's usage-limit menu from opening by itself while the
// auto-resume waiter is wired, because the open menu holds the wake-up.
//
// When a turn dies on a usage limit whose reset is more than a day out (in
// practice the weekly one), Claude Code arms no automatic continue of its own
// and opens /rate-limit-options instead ("Stop and wait for limit to reset",
// "Wait here, then continue automatically", "Upgrade your plan"). That menu is
// a command panel that holds the session's queue: the waiter's wake-up, which
// arrives as a queued task notification, and the /reload-plugins the switch
// module queues both wait until someone presses Esc, so a switch to a login
// with room reached the session only when a person came back to it. Within a
// day of the reset Claude Code continues by itself and opens no menu, and
// nothing here acts.
//
// The menu opens by running the command as if typed: its command.run carries
// the same origin (`composer`) as the person typing it. What distinguishes
// the automatic one is that it follows the end of a main-loop turn that died
// on an API error by about a tenth of a second. So the first
// rate-limit-options within WINDOW_MS of such a death is answered here, and
// every other one opens the menu: typing /rate-limit-options opens it, at once
// after a death too, by typing it a second time. Answering without next() runs
// no command and opens no panel; the answer is drawn as the command's output,
// under this plugin's name. The death is read off turn.complete, which names no error
// kind, rather than classic.StopFailure, which does: a classic hook does not
// run in a plugin a person installs where an organization manages Claude Code.
// Any error will do, since the menu opens only after a usage limit. Observed on
// Claude Code 2.1.302.
//
// Only while the waiter is wired (a StopFailure entry running
// `--rewake-waiter` with asyncRewake): without it, as after an install with
// --no-rewake, the menu's own "continue automatically" choice is the only
// wake-up there is, and the menu is left alone.
const WINDOW_MS = 5_000

type HookEntry = { command?: string; asyncRewake?: boolean }

const waiterWired = (hooks: unknown) =>
  ((hooks as { StopFailure?: { hooks?: HookEntry[] }[] } | undefined)?.StopFailure ?? []).some((g) =>
    (g.hooks ?? []).some((h) => h.asyncRewake === true && (h.command ?? '').includes('--rewake-waiter')))

export const register: Register = (on) => {
  let diedAt: number | undefined

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined && e.reason === 'error') diedAt = await $.clock.now()
    return next(e)
  })

  on('command.run', { command: 'rate-limit-options' }, async ($, e, next) => {
    const died = diedAt
    diedAt = undefined
    if (died === undefined || (await $.clock.now()) - died > WINDOW_MS) return next(e)
    if (!waiterWired((await $.settings.read()).hooks)) return next(e)
    return {
      text: 'usage-limit menu not opened: the auto-resume waiter wakes this session when the limit resets or the login switches. Type /rate-limit-options to open it.',
    }
  })
}
