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
// the merged settings, and the menu itself, which records that it opened.
function world(on: On, settings: Readonly<Record<string, unknown>> = WIRED) {
  const clock = mock.clock(on)
  on('settings.read', () => ({ value: settings }))
  on('turn.complete', () => ({ text: '' }))
  const opened: string[] = []
  on('command.run', ($, e) => {
    opened.push(e.command)
    return { text: '' }
  })
  return { clock, opened }
}

const death = (agentId?: string) =>
  ({ answer: '', durationMs: 200, isAborted: false, turnId: 't1', reason: 'error' as const, ...(agentId ? { agentId } : {}) })
// As the automatic open arrives, and the typed command too: the composer's origin.
const MENU = {
  command: 'rate-limit-options', args: '', origin: { kind: 'composer' as const },
  presentation: { isFullscreen: false, columns: 80 },
}

test('the menu Claude Code opens right after a main-loop turn died is not opened', async ($, on) => {
  const w = world(on)
  await $.turn.complete(death())
  await w.clock.advance(100)
  const r = await $.command.run(MENU)
  expect(w.opened).toEqual([])
  expect(r.text).toContain('Type /rate-limit-options to open it')
})

test('typing /rate-limit-options again opens it', async ($, on) => {
  const w = world(on)
  await $.turn.complete(death())
  await $.command.run(MENU)
  await $.command.run(MENU)
  expect(w.opened).toEqual(['rate-limit-options'])
})

test('a menu asked for long after the death opens', async ($, on) => {
  const w = world(on)
  await $.turn.complete(death())
  await w.clock.advance(6_000)
  await $.command.run(MENU)
  expect(w.opened).toEqual(['rate-limit-options'])
})

test('a menu with no death before it opens', async ($, on) => {
  const w = world(on)
  await $.command.run(MENU)
  expect(w.opened).toEqual(['rate-limit-options'])
})

test("a subagent's death, which opens no menu, holds nothing back", async ($, on) => {
  const w = world(on)
  await $.turn.complete(death('a123'))
  await $.command.run(MENU)
  expect(w.opened).toEqual(['rate-limit-options'])
})

test('a turn that ended with an answer holds nothing back', async ($, on) => {
  const w = world(on)
  await $.turn.complete({ ...death(), reason: 'answer' as const })
  await $.command.run(MENU)
  expect(w.opened).toEqual(['rate-limit-options'])
})

test('without the waiter wired the menu opens, since its own choice is the only wake-up', async ($, on) => {
  const w = world(on, UNWIRED)
  await $.turn.complete(death())
  await $.command.run(MENU)
  expect(w.opened).toEqual(['rate-limit-options'])
})

test('a waiter entry that is not asyncRewake does not count as wired', async ($, on) => {
  const w = world(on, { hooks: { StopFailure: [{ hooks: [{ type: 'command', command: 'bash /clone/session --rewake-waiter' }] }] } })
  await $.turn.complete(death())
  await $.command.run(MENU)
  expect(w.opened).toEqual(['rate-limit-options'])
})
