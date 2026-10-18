// Tests for rate-limit-menu.ts: claude plugin test <clone>
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const WIRED = {
  hooks: {
    StopFailure: [{ hooks: [
      { type: 'command', command: 'bash /clone/session --turn-fail || true', timeout: 2 },
      { type: 'command', command: 'bash /clone/session --rewake-waiter', asyncRewake: true },
    ] }],
  },
}
const UNWIRED = {
  hooks: { StopFailure: [{ hooks: [{ type: 'command', command: 'bash /clone/session --turn-fail || true' }] }] },
}

// The world beneath the module: a clock that moves only when the test moves it,
// the merged settings (or a read that fails), and the commands themselves, which
// record that they ran and answer with their own name.
function world(on: On, settings: Readonly<Record<string, unknown>> | 'denied' = WIRED) {
  const clock = mock.clock(on)
  on('settings.read', () => (settings === 'denied' ? { deny: 'EIO' } : { value: settings }))
  on('turn.complete', () => ({ text: 'core answer' }))
  const ran: string[] = []
  on('command.run', ($, e) => {
    ran.push(e.args ? `${e.command} ${e.args}` : e.command)
    return { text: `core ${e.command}` }
  })
  return { clock, ran }
}

const death = (agentId?: string) =>
  ({ answer: '', durationMs: 200, isAborted: false, turnId: 't1', reason: 'error' as const, ...(agentId ? { agentId } : {}) })
// The automatic open and a typed command carry the same event, origin `composer` included.
const run = (command: string, args = '') =>
  ({ command, args, origin: { kind: 'composer' as const }, presentation: { isFullscreen: false, columns: 80 } })
const MENU = run('rate-limit-options')

test('the menu Claude Code opens right after a main-loop turn died is not opened', async ($, on) => {
  const w = world(on)
  await $.turn.complete(death())
  await w.clock.advance(100)
  const r = await $.command.run(MENU)
  expect(w.ran).toEqual([])
  expect(r.text).toContain('Type /rate-limit-options to open it')
})

test('typing /rate-limit-options again opens it', async ($, on) => {
  const w = world(on)
  await $.turn.complete(death())
  await $.command.run(MENU)
  await $.command.run(MENU)
  expect(w.ran).toEqual(['rate-limit-options'])
})

test('a menu asked for long after the death opens', async ($, on) => {
  const w = world(on)
  await $.turn.complete(death())
  await w.clock.advance(6_000)
  await $.command.run(MENU)
  expect(w.ran).toEqual(['rate-limit-options'])
})

test('a menu with no death before it opens', async ($, on) => {
  const w = world(on)
  await $.command.run(MENU)
  expect(w.ran).toEqual(['rate-limit-options'])
})

test("a subagent's death is not a main-loop death and does not suppress a later menu", async ($, on) => {
  const w = world(on)
  await $.turn.complete(death('a123'))
  await $.command.run(MENU)
  expect(w.ran).toEqual(['rate-limit-options'])
})

test('a turn that ended with an answer does not suppress a later menu', async ($, on) => {
  const w = world(on)
  await $.turn.complete({ ...death(), reason: 'answer' as const })
  await $.command.run(MENU)
  expect(w.ran).toEqual(['rate-limit-options'])
})

test('a second death restarts the window', async ($, on) => {
  const w = world(on)
  await $.turn.complete(death())
  await w.clock.advance(4_000)
  await $.turn.complete(death())
  await w.clock.advance(4_000)
  await $.command.run(MENU)
  expect(w.ran).toEqual([])
})

// The switch module runs /reload-plugins seconds after a cap death moved the
// login: it must run, and it must not use up the death the menu is matched on.
test('another command right after a death runs, and the menu after it is still not opened', async ($, on) => {
  const w = world(on)
  await $.turn.complete(death())
  const r = await $.command.run(run('reload-plugins', 'login switched'))
  await $.command.run(MENU)
  expect(r.text).toBe('core reload-plugins')
  expect(w.ran).toEqual(['reload-plugins login switched'])
})

test('what the module passes through is what lies beneath it', async ($, on) => {
  const w = world(on)
  const done = await $.turn.complete(death())
  expect(done.text).toBe('core answer')
  await w.clock.advance(6_000)
  const r = await $.command.run(run('rate-limit-options', 'some args'))
  expect(r.text).toBe('core rate-limit-options')
  expect(w.ran).toEqual(['rate-limit-options some args'])
})

test('without the waiter wired the menu opens, since its own choice is the only wake-up', async ($, on) => {
  const w = world(on, UNWIRED)
  await $.turn.complete(death())
  await $.command.run(MENU)
  expect(w.ran).toEqual(['rate-limit-options'])
})

test('a waiter entry that is not asyncRewake does not count as wired', async ($, on) => {
  const w = world(on, { hooks: { StopFailure: [{ hooks: [{ type: 'command', command: 'bash /clone/session --rewake-waiter' }] }] } })
  await $.turn.complete(death())
  await $.command.run(MENU)
  expect(w.ran).toEqual(['rate-limit-options'])
})

test('an asyncRewake StopFailure hook of something else does not count as wired', async ($, on) => {
  const w = world(on, { hooks: { StopFailure: [{ hooks: [{ type: 'command', command: '/usr/local/bin/notify-me', asyncRewake: true }] }] } })
  await $.turn.complete(death())
  await $.command.run(MENU)
  expect(w.ran).toEqual(['rate-limit-options'])
})

test('settings that cannot be read leave the menu to open', async ($, on) => {
  const w = world(on, 'denied')
  await $.turn.complete(death())
  await $.command.run(MENU)
  expect(w.ran).toEqual(['rate-limit-options'])
})
