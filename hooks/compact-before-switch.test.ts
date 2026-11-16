// Tests for compact-before-switch.ts: claude plugin test <clone>
import { expect, mock, test } from 'claude-code/testing'
import type { On } from 'claude-code'

const CFG = '/cfg'
const MARKER = `${CFG}/.session-switch-soon`
const SWITCHED = `${CFG}/.session-login-switch`
const START = { cwd: '/w', surface: 'terminal', isInteractive: true } as const
const NOW = 1_800_000_000_000
const HOUR = 3_600_000
const BIG = 250_000

// What the CLI writes when the live login nears a window's end and another
// login could take over (the pre-switch ask in lib/account.sh).
const soon = (reset = NOW / 1000 + 3600) => `login=a@example.com\nto=b@example.com\nreset=${reset}\n`

// The world beneath the module: a clock that moves only when the test moves it,
// the environment it reads, the files it stats and reads (mtime and text per
// path, absent: no such file), the context size the session reports, and what
// the engine does with a compaction, a prompt and a model request.
function world(on: On, { env = { CLAUDE_CONFIG_DIR: CFG } }: { env?: Record<string, string> } = {}) {
  const clock = mock.clock(on, { now: NOW })
  mock.env(on, env)
  const files: Record<string, { mtime: number; text?: string }> = {}
  const w = {
    clock,
    files,
    tokens: undefined as number | undefined,
    compaction: 'ok' as 'ok' | 'veto' | 'reject',
    // A compaction under way: the engine answers the call only once this resolves.
    running: undefined as Promise<void> | undefined,
    refuseSubmit: false,
    // The engine rejecting a call outright, as a hook's deny or a changed API would.
    submitThrows: false,
    usageThrows: false,
    compacts: [] as string[],
    submits: [] as string[],
    logs: [] as string[],
    requests: [] as number[],
  }
  on('fs.stat', ($, e) => {
    const file = files[e.path]
    return file ? { value: { kind: 'file', size: 1, mtimeMs: file.mtime, isLink: false } } : { deny: 'ENOENT' }
  })
  on('fs.read', ($, e) => {
    const text = files[e.path]?.text
    return text !== undefined ? { value: text } : { deny: 'ENOENT' }
  })
  on('session.usage', () => {
    if (w.usageThrows) throw new Error('no usage')
    return {
    value: { startedAt: 0, context: { window: 1_000_000, ...(w.tokens === undefined ? {} : { tokens: w.tokens }) }, rateLimits: [] },
    }
  })
  // The call reads the transcript to hand the hooks beneath it.
  on('session.messages', () => ({ value: [] }))
  on('session.compact', async ($, e) => {
    w.compacts.push('compact')
    await w.running
    if (w.compaction === 'reject') throw new Error('a turn is running')
    if (w.compaction === 'veto') return { skip: 'held by a hook' }
    return { messages: [{ role: 'user', text: 'summary', toolUses: [] }] }
  })
  on('prompt.submit', ($, e) => {
    w.submits.push(e.text)
    if (w.submitThrows) throw new Error('denied')
    return w.refuseSubmit ? { drop: 'refused' } : { text: e.text, origin: e.origin }
  })
  on('ui.log', ($, e) => {
    w.logs.push(e.text)
    return { value: undefined }
  })
  on('session.start', ($, e) => ({ cwd: e.cwd }))
  on('turn.start', ($, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: '' }))
  on('turn.step', async function* ($, e) {
    w.requests.push(e.index)
    return { turnId: e.turnId, index: e.index, answer: 'ok', toolUses: [], stopReason: 'end_turn', usage: null } as const
  })
  return w
}

type Calls = {
  turn: {
    start: (e: { text: string; turnId: string }) => Promise<unknown>
    complete: (e: { answer: string; durationMs: number; isAborted: boolean; turnId: string; reason: 'answer' }) => Promise<unknown>
    step: (e: { turnId: string; index: number; model: string; messageCount: number; agentId?: string }) => AsyncGenerator<unknown> & { result: Promise<unknown> }
  }
}
const begin = ($: Calls) => $.turn.start({ text: '', turnId: 't1' })
const end = ($: Calls) => $.turn.complete({ answer: '', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' })
// One model request of the running turn, as the engine raises it.
async function step($: Calls, index: number, agentId?: string) {
  const stream = $.turn.step({ turnId: 't1', index, model: 'm', messageCount: 3, ...(agentId ? { agentId } : {}) })
  let next = await stream.next()
  while (!next.done) next = await stream.next()
  return next.value
}

// A session whose last turn ended a moment ago, with a marker written since it
// started: the ordinary case, to which each test below changes one thing.
async function ready($: Calls & { session: { start: (e: typeof START) => Promise<unknown> } }, w: ReturnType<typeof world>, tokens = BIG) {
  w.tokens = tokens
  await $.session.start(START)
  await begin($)
  await end($)
}
const write = (w: ReturnType<typeof world>, mtime: number, text = soon()) => {
  w.files[MARKER] = { mtime, text }
}

test('a session over the floor with a warm cache compacts once when the marker is written', async ($, on) => {
  const w = world(on)
  await ready($, w)
  await w.clock.advance(10_000)
  expect(w.compacts).toEqual([])
  write(w, 1000)
  await w.clock.advance(10_000)
  expect(w.compacts).toEqual(['compact'])
  expect(w.logs).toHaveLength(1)
  expect(w.logs[0]).toContain('a@example.com')
  expect(w.submits).toEqual([])
  await w.clock.advance(60_000)
  expect(w.compacts).toHaveLength(1)
})

test('the same marker rewritten compacts nothing more; a marker for another window does', async ($, on) => {
  const w = world(on)
  await ready($, w)
  write(w, 1000)
  await w.clock.advance(10_000)
  w.tokens = BIG
  write(w, 2000)
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
  write(w, 3000, soon(NOW / 1000 + 7200))
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(2)
})

test('a session under the floor, or one that has not answered since a compaction, is left alone', async ($, on) => {
  const w = world(on)
  await ready($, w, 199_999)
  write(w, 1000)
  await w.clock.advance(30_000)
  expect(w.compacts).toEqual([])
  w.tokens = undefined
  write(w, 2000, soon(NOW / 1000 + 7200))
  await w.clock.advance(30_000)
  expect(w.compacts).toEqual([])
})

test('a session that grows past the floor after the marker landed is compacted then', async ($, on) => {
  const w = world(on)
  await ready($, w, 150_000)
  write(w, 1000)
  await w.clock.advance(30_000)
  expect(w.compacts).toEqual([])
  w.tokens = BIG
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
})

test('a session whose cache was cold when the marker landed is compacted once it is warm again', { timeoutMs: 120_000 }, async ($, on) => {
  const w = world(on)
  await ready($, w)
  await w.clock.advance(HOUR + 1000)
  write(w, 1000, soon(NOW / 1000 + 7200))
  await w.clock.advance(30_000)
  expect(w.compacts).toEqual([])
  await begin($)
  await end($)
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
})

test('a session at the floor exactly is compacted', async ($, on) => {
  const w = world(on)
  await ready($, w, 200_000)
  write(w, 1000)
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
})

test('a cache that has been cold for an hour is left alone', { timeoutMs: 120_000 }, async ($, on) => {
  const w = world(on)
  await ready($, w)
  await w.clock.advance(HOUR + 1000)
  write(w, 1000, soon(NOW / 1000 + 7200))
  await w.clock.advance(10_000)
  expect(w.compacts).toEqual([])
})

test('a cache last used 59 minutes ago is still warm', { timeoutMs: 120_000 }, async ($, on) => {
  const w = world(on)
  await ready($, w)
  await w.clock.advance(HOUR - 60_000)
  write(w, 1000)
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
})

test('a session that has run no turn has no warm cache', async ($, on) => {
  const w = world(on)
  w.tokens = BIG
  await $.session.start(START)
  write(w, 1000)
  await w.clock.advance(30_000)
  expect(w.compacts).toEqual([])
})

test('a marker that names no login or reset is ignored', async ($, on) => {
  const w = world(on)
  await ready($, w)
  write(w, 1000, 'login=a@example.com\n')
  await w.clock.advance(30_000)
  write(w, 2000, 'garbled')
  await w.clock.advance(30_000)
  expect(w.compacts).toEqual([])
})

test('a marker already there when the session started triggers nothing', async ($, on) => {
  const w = world(on)
  write(w, 1000)
  await ready($, w)
  await w.clock.advance(60_000)
  expect(w.compacts).toEqual([])
})

test('a session that is not interactive never compacts', async ($, on) => {
  const w = world(on)
  w.tokens = BIG
  await $.session.start({ ...START, isInteractive: false })
  await begin($)
  await end($)
  write(w, 1000)
  await w.clock.advance(60_000)
  expect(w.compacts).toEqual([])
})

test('a marker whose window has already reset triggers nothing', async ($, on) => {
  const w = world(on)
  await ready($, w)
  write(w, 1000, soon(NOW / 1000 - 1))
  await w.clock.advance(30_000)
  expect(w.compacts).toEqual([])
})

test('once the box has switched, compacting would read the context uncached, so nothing runs', async ($, on) => {
  const w = world(on)
  await ready($, w)
  write(w, 1000)
  w.files[SWITCHED] = { mtime: 1500 }
  await w.clock.advance(30_000)
  expect(w.compacts).toEqual([])
})

test('a switch older than the marker does not count', async ($, on) => {
  const w = world(on)
  await ready($, w)
  write(w, 2000)
  w.files[SWITCHED] = { mtime: 1500 }
  await w.clock.advance(30_000)
  expect(w.compacts).toHaveLength(1)
})

test('a switch that lands while the session waits for its turn to end cancels the compaction', async ($, on) => {
  const w = world(on)
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(10_000)
  w.files[SWITCHED] = { mtime: 2000 }
  await w.clock.advance(10_000)
  await end($)
  await w.clock.advance(10_000)
  expect(w.compacts).toEqual([])
})

test('a compaction waits for the turn to end and settle', async ($, on) => {
  const w = world(on)
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(63_500)
  expect(w.compacts).toEqual([])
  // The poll 1.5 s after the turn ended finds it not yet settled.
  await end($)
  await w.clock.advance(1500)
  expect(w.compacts).toEqual([])
  await w.clock.advance(5000)
  expect(w.compacts).toHaveLength(1)
  expect(w.submits).toEqual([])
})

test('a failed compaction is logged and not tried again for that marker', async ($, on) => {
  const w = world(on)
  w.compaction = 'reject'
  await ready($, w)
  write(w, 1000)
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
  expect(w.logs.join('\n')).toContain('compaction ahead of a login switch failed')
  await w.clock.advance(60_000)
  expect(w.compacts).toHaveLength(1)
})

test('a compaction a hook vetoed is logged and not tried again for that marker', async ($, on) => {
  const w = world(on)
  w.compaction = 'veto'
  await ready($, w)
  write(w, 1000)
  await w.clock.advance(10_000)
  expect(w.logs.join('\n')).toContain('held by a hook')
  await w.clock.advance(60_000)
  expect(w.compacts).toHaveLength(1)
})

test('mid-turn, the next model request is not sent; the turn is compacted and continued once it has ended', async ($, on) => {
  const w = world(on)
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  await step($, 0)
  write(w, 1000)
  await w.clock.advance(5000)
  expect(w.compacts).toEqual([])

  const answered = await step($, 1)
  expect(w.requests).toEqual([0])
  expect(answered).toMatchObject({ index: 1, toolUses: [], stopReason: 'end_turn' })

  await end($)
  await w.clock.advance(1000)
  expect(w.compacts).toEqual([])
  await w.clock.advance(10_000)
  expect(w.compacts).toEqual(['compact'])
  expect(w.submits).toHaveLength(1)
  expect(w.submits[0]).toContain('paused to compact the conversation ahead of a login switch')
  expect(w.submits[0]).toContain('Continue where you left off')
  await w.clock.advance(60_000)
  expect(w.compacts).toHaveLength(1)
  expect(w.submits).toHaveLength(1)
})

test('a stopped request does not stop the one after it', async ($, on) => {
  const w = world(on)
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(5000)
  await step($, 0)
  await step($, 1)
  expect(w.requests).toEqual([1])
})

test('a request before the marker is sent', async ($, on) => {
  const w = world(on)
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  await step($, 0)
  expect(w.requests).toEqual([0])
})

test('a request from a subagent is sent', async ($, on) => {
  const w = world(on)
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(5000)
  await step($, 0, 'sub-1')
  expect(w.requests).toEqual([0])
  await step($, 1)
  expect(w.requests).toEqual([0])
})

test('a request of a session under the floor is sent', async ($, on) => {
  const w = world(on)
  w.tokens = 100_000
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(5000)
  await step($, 0)
  expect(w.requests).toEqual([0])
})

test('a switch between the stopped request and the compaction skips the compaction but still continues the turn', async ($, on) => {
  const w = world(on)
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(5000)
  await step($, 0)
  w.files[SWITCHED] = { mtime: 2000 }
  await end($)
  await w.clock.advance(10_000)
  expect(w.compacts).toEqual([])
  expect(w.submits).toHaveLength(1)
  expect(w.submits[0]).toContain('Continue where you left off')
})

test('a failed compaction after a stopped request still continues the turn', async ($, on) => {
  const w = world(on)
  w.compaction = 'reject'
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(5000)
  await step($, 0)
  await end($)
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
  expect(w.submits).toHaveLength(1)
})

// A reload of the plugin's code during the compaction drops this module's
// state, so the prompt that continues the turn has to be the engine's by then.
test('the turn\'s continuation is submitted while the compaction is still running', async ($, on) => {
  const w = world(on)
  let finish = () => {}
  w.running = new Promise<void>((resolve) => {
    finish = resolve
  })
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(5000)
  await step($, 0)
  await end($)
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
  expect(w.submits).toHaveLength(1)
  finish()
})

test('a continuation the engine refuses is logged', async ($, on) => {
  const w = world(on)
  w.refuseSubmit = true
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(5000)
  await step($, 0)
  await end($)
  await w.clock.advance(10_000)
  expect(w.submits).toHaveLength(1)
  expect(w.logs.join('\n')).toContain('was not continued: refused')
})

test('a continuation the engine rejects is logged as a turn left paused', async ($, on) => {
  const w = world(on)
  w.submitThrows = true
  w.tokens = BIG
  await $.session.start(START)
  await begin($)
  write(w, 1000)
  await w.clock.advance(5000)
  await step($, 0)
  await end($)
  await w.clock.advance(10_000)
  expect(w.submits).toHaveLength(1)
  expect(w.logs.join('\n')).toContain('was not continued: ')
})

test('a marker that is removed cancels the compaction it asked for', async ($, on) => {
  const w = world(on)
  await ready($, w, 150_000)
  write(w, 1000)
  await w.clock.advance(10_000)
  delete w.files[MARKER]
  await w.clock.advance(10_000)
  w.tokens = BIG
  await w.clock.advance(30_000)
  expect(w.compacts).toEqual([])
})

test('after an idle compaction the next turn\'s requests are sent', async ($, on) => {
  const w = world(on)
  await ready($, w)
  write(w, 1000)
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
  await begin($)
  await step($, 0)
  expect(w.requests).toEqual([0])
  await end($)
  await w.clock.advance(10_000)
  expect(w.submits).toEqual([])
})

test('a check that keeps failing the same way is logged once', async ($, on) => {
  const w = world(on)
  w.usageThrows = true
  await ready($, w)
  write(w, 1000)
  await w.clock.advance(60_000)
  expect(w.logs).toHaveLength(1)
  expect(w.logs[0]).toContain('the check for a compaction ahead of a login switch failed')
})

test('SESSION_SWITCH_SOON_MARKER names the marker in place of the config directory\'s', async ($, on) => {
  const scratch = '/scratch/soon'
  const w = world(on, { env: { CLAUDE_CONFIG_DIR: CFG, SESSION_SWITCH_SOON_MARKER: scratch } })
  await ready($, w)
  write(w, 1000)
  await w.clock.advance(10_000)
  expect(w.compacts).toEqual([])
  w.files[scratch] = { mtime: 2000, text: soon() }
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
})

test('SESSION_LOGIN_SWITCH_MARKER names the marker a switch writes', async ($, on) => {
  const scratch = '/scratch/switch'
  const w = world(on, { env: { CLAUDE_CONFIG_DIR: CFG, SESSION_LOGIN_SWITCH_MARKER: scratch } })
  await ready($, w)
  write(w, 1000)
  w.files[scratch] = { mtime: 2000 }
  await w.clock.advance(10_000)
  expect(w.compacts).toEqual([])
})

test('SESSION_PRE_SWITCH_COMPACT_FLOOR moves the floor', async ($, on) => {
  const w = world(on, { env: { CLAUDE_CONFIG_DIR: CFG, SESSION_PRE_SWITCH_COMPACT_FLOOR: '1000' } })
  await ready($, w, 1500)
  write(w, 1000)
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
})

test('without CLAUDE_CONFIG_DIR the marker is the one under ~/.claude', async ($, on) => {
  const w = world(on, { env: { HOME: '/h' } })
  await ready($, w)
  w.files['/h/.claude/.session-switch-soon'] = { mtime: 1000, text: soon() }
  await w.clock.advance(10_000)
  expect(w.compacts).toHaveLength(1)
})
