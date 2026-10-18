// Tests for reload-on-switch.ts: claude plugin test <clone>
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const CFG = '/cfg'
const MARKER = `${CFG}/.session-login-switch`
const START = { cwd: '/w', surface: 'terminal', isInteractive: true } as const

// The world beneath the module: a clock that moves only when the test moves it,
// the environment it reads, the marker at `marker` (its mtime, undefined: no
// marker yet; its text, undefined: unreadable), every path it stats, and every
// command it runs as the person would type it, refused when `refuse` says so.
function world(on: On, { env = { CLAUDE_CONFIG_DIR: CFG }, marker = MARKER, refuse = false }:
  { env?: Record<string, string>; marker?: string; refuse?: boolean } = {}) {
  const clock = mock.clock(on)
  mock.env(on, env)
  const fs: { mtime?: number; text?: string; asked: string[] } = { asked: [] }
  on('fs.stat', ($, e) => {
    fs.asked.push(e.path)
    return e.path === marker && fs.mtime !== undefined
      ? { value: { kind: 'file', size: 14, mtimeMs: fs.mtime, isLink: false } }
      : { deny: 'ENOENT' }
  })
  on('fs.read', ($, e) =>
    e.path === marker && fs.text !== undefined ? { value: fs.text } : { deny: 'ENOENT' })
  const runs: string[] = []
  on('command.run', ($, e) => {
    runs.push(e.args ? `${e.command} ${e.args}` : e.command)
    if (refuse) throw new Error('refused')
    return { text: 'Reloaded' }
  })
  on('ui.log', () => ({ value: undefined }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  return { clock, fs, runs }
}

// A main-loop turn, begun and ended by the test.
const begin = ($: { turn: { start: (e: { text: string; turnId: string }) => Promise<unknown> } }) =>
  $.turn.start({ text: '', turnId: 't1' })
const end = ($: { turn: { complete: (e: { answer: string; durationMs: number; isAborted: boolean; turnId: string; reason: 'answer' }) => Promise<unknown> } }) =>
  $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })

test('a marker that does not move runs nothing', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  await w.clock.advance(60_000)
  expect(w.runs).toEqual([])
  expect(w.fs.asked[0]).toBe(MARKER)
})

test('each move of the marker runs /reload-plugins once', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  w.fs.mtime = 2000
  await w.clock.advance(5_000)
  expect(w.runs).toEqual(['reload-plugins'])
  await w.clock.advance(60_000)
  expect(w.runs).toEqual(['reload-plugins'])
  w.fs.mtime = 3000
  await w.clock.advance(5_000)
  expect(w.runs).toEqual(['reload-plugins', 'reload-plugins'])
})

test('a marker first written after the session started is a switch', async ($, on) => {
  const w = world(on)
  await $.session.start(START)
  await w.clock.advance(10_000)
  expect(w.runs).toEqual([])
  w.fs.mtime = 1000
  await w.clock.advance(5_000)
  expect(w.runs).toEqual(['reload-plugins'])
})

// The marker counts as seen before the reload is queued, so a reload that keeps
// failing is tried once per switch rather than on every poll.
test('a reload that fails is not tried again on every poll', async ($, on) => {
  const w = world(on, { refuse: true })
  w.fs.mtime = 1000
  await $.session.start(START)
  w.fs.mtime = 2000
  await w.clock.advance(60_000)
  expect(w.runs).toEqual(['reload-plugins'])
})

test('without CLAUDE_CONFIG_DIR the marker is the one under ~/.claude', async ($, on) => {
  const w = world(on, { env: { HOME: '/h' } })
  await $.session.start(START)
  expect(w.fs.asked[0]).toBe('/h/.claude/.session-login-switch')
})

// The swap writes who the box moved from and to and why (acct_swap in the CLI);
// the command row Claude Code draws for the reload carries them as its arguments.
const SWITCH = 'from=a@example.com\nto=b@example.com\nreason=5h limit\n'
const NOTE = 'reload-plugins login switched from a@example.com to b@example.com (5h limit)'

test('the reload row says which login the box moved from and to, and why', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  w.fs.mtime = 2000
  w.fs.text = SWITCH
  await w.clock.advance(5_000)
  expect(w.runs).toEqual([NOTE])
})

test('a marker with no from and to still reloads, with no note', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  w.fs.mtime = 2000
  w.fs.text = 'b@example.com\n'
  await w.clock.advance(5_000)
  expect(w.runs).toEqual(['reload-plugins'])
})

test('a marker that cannot be read still reloads, with no note', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  w.fs.mtime = 2000
  await w.clock.advance(5_000)
  expect(w.runs).toEqual(['reload-plugins'])
})

test('a marker already there at session start is not announced', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  w.fs.text = SWITCH
  await $.session.start(START)
  await w.clock.advance(60_000)
  expect(w.runs).toEqual([])
})

test('each switch carries its own note', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  w.fs.mtime = 2000
  w.fs.text = SWITCH
  await w.clock.advance(5_000)
  w.fs.mtime = 3000
  w.fs.text = 'from=b@example.com\nto=c@example.com\nreason=session account use\n'
  await w.clock.advance(5_000)
  expect(w.runs).toEqual([
    NOTE,
    'reload-plugins login switched from b@example.com to c@example.com (session account use)',
  ])
})

test('SESSION_LOGIN_SWITCH_MARKER names the marker in place of the config directory\'s', async ($, on) => {
  const scratch = '/scratch/marker'
  const w = world(on, { env: { CLAUDE_CONFIG_DIR: CFG, SESSION_LOGIN_SWITCH_MARKER: scratch }, marker: scratch })
  w.fs.mtime = 1000
  await $.session.start(START)
  w.fs.mtime = 2000
  w.fs.text = SWITCH
  await w.clock.advance(5_000)
  expect(w.fs.asked).not.toContain(MARKER)
  expect(w.runs).toEqual([NOTE])
})

// A command queued during a turn waits under the conversation until the session
// is idle; held here instead, it is queued only when it can run.
test('a switch seen during a turn reloads once the turn has ended', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  await begin($)
  w.fs.mtime = 2000
  w.fs.text = SWITCH
  await w.clock.advance(60_000)
  expect(w.runs).toEqual([])
  await end($)
  await w.clock.advance(5_000)
  expect(w.runs).toEqual([NOTE])
})

test('an idle moment shorter than the settle time is not taken', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  await begin($)
  w.fs.mtime = 2000
  await w.clock.advance(4_000)
  await end($)
  await w.clock.advance(1_000)
  expect(w.runs).toEqual([])
  await w.clock.advance(5_000)
  expect(w.runs).toEqual(['reload-plugins'])
})

test('a turn that starts as the last one ends is no idle moment', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  await begin($)
  w.fs.mtime = 2000
  await w.clock.advance(5_000)
  await end($)
  await begin($)
  await w.clock.advance(30_000)
  expect(w.runs).toEqual([])
  await end($)
  await w.clock.advance(5_000)
  expect(w.runs).toEqual(['reload-plugins'])
})

test('two switches during one turn reload once, with the later note', async ($, on) => {
  const w = world(on)
  w.fs.mtime = 1000
  await $.session.start(START)
  await begin($)
  w.fs.mtime = 2000
  w.fs.text = SWITCH
  await w.clock.advance(5_000)
  w.fs.mtime = 3000
  w.fs.text = 'from=b@example.com\nto=c@example.com\nreason=session account use\n'
  await w.clock.advance(5_000)
  await end($)
  await w.clock.advance(5_000)
  expect(w.runs).toEqual(['reload-plugins login switched from b@example.com to c@example.com (session account use)'])
})
