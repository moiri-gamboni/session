// Tests for reload-on-switch.ts: claude plugin test <clone>
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const CFG = '/cfg'
const MARKER = `${CFG}/.session-login-switch`
const START = { cwd: '/w', surface: 'terminal', isInteractive: true } as const

// The world beneath the module: a clock that moves only when the test moves it,
// the environment it reads, the marker's mtime (undefined: no marker yet), every
// path it stats, and every command it runs, refused when `refuse` says so.
function world(on: On, { env = { CLAUDE_CONFIG_DIR: CFG }, refuse = false }:
  { env?: Record<string, string>; refuse?: boolean } = {}) {
  const clock = mock.clock(on)
  mock.env(on, env)
  const fs: { mtime?: number; asked: string[] } = { asked: [] }
  on('fs.stat', ($, e) => {
    fs.asked.push(e.path)
    return e.path.endsWith('/.session-login-switch') && fs.mtime !== undefined
      ? { value: { kind: 'file', size: 14, mtimeMs: fs.mtime, isLink: false } }
      : { deny: 'ENOENT' }
  })
  const runs: string[] = []
  on('command.run', ($, e) => {
    runs.push(e.command)
    if (refuse) throw new Error('refused')
    return { text: 'Reloaded' }
  })
  on('ui.log', () => ({ value: undefined }))
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  return { clock, fs, runs }
}

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
