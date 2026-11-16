import type { On } from 'claude-code'
import type { MainLoop } from './main-loop'

// Compact a session shortly before the box moves to another login.
//
// A session's prompt cache belongs to the login that wrote it. After a switch
// each session with a warm cache rewrites its whole context into the new
// login's cache on its next request, so the larger the context, the more that
// costs; compacted first, the new login caches a fraction of it. The CLI says a
// switch is coming by writing the marker below when the live login nears the end
// of a window and another saved login could take over (acct_switch_soon in the
// CLI), three lines: login= the live login, to= the login the box would move
// to, reset= the epoch second its window resets. The login and the reset name
// the marker. A session compacts at most once for each marker, and not at all
// when the box has already switched, because compacting then reads the whole
// context uncached on the new login: .session-login-switch newer than the
// marker is that switch. A marker that is removed cancels what it asked for,
// which is how SESSION_PRE_SWITCH_COMPACT=off and SESSION_AUTO_SWITCH=off reach
// a session: the status line removes the marker, and this module never reads
// the conf.
//
// Compacting needs a context worth it and a cache that is warm: FLOOR tokens or
// more, and a main-loop turn running or one that ended less than WARM_MS ago,
// the one-hour prompt-cache lifetime (Claude Code's promptCacheTtl of 1h;
// under the shorter default a session idle past it is compacted cold).
// A cold cache gains nothing, since the compaction itself would read the whole
// context uncached, as the session's next request would anyway, and a session
// under the floor has little to save. A session that does not qualify when the
// marker lands keeps it pending, so one that grows past the floor or warms up
// before the box moves is compacted then. Subagents and headless runs are left
// alone: only interactive sessions start the poll, and a subagent's requests
// are never stopped.
//
// `context.tokens` of $.session.usage() is what the last request carried (input,
// cache-written and cache-read, not output), not a running total, and is absent
// until a response has come back after a compaction. Observed on Claude Code
// 2.1.325 beside the status line's context figure, which adds the response's
// output tokens.
//
// $.session.compact() runs between turns and rejects while one runs, so a
// session that is idle, with the main loop settled for SETTLE_MS as the reload
// module waits, compacts at the next poll. One in the middle of a turn is
// stopped at its next model request: the turn.step hook answers it without
// calling next, which sends no request and ends the turn with the tool results
// it already holds in the transcript. Once the turn has ended the poll starts
// the compaction and, without waiting for it, submits the prompt that carries
// the work on. The engine holds a plugin's prompt until the session is idle, so
// it runs after the compaction, and it is the engine's from then on: a reload
// of the plugin's code during the compaction drops this module's state, and a
// prompt submitted only after the compaction was lost with it, leaving the
// turn stopped. Observed on Claude Code 2.1.325: the turn ends with reason
// `answer`, the transcript keeps every tool_use paired with its tool_result,
// the prompt is drawn under the conversation while the compaction runs, and
// the model finishes the task from the summary, through such a reload too;
// stopped at its first request, the user's prompt survives the compaction. The
// turn's end fires the Stop hooks and the submitted prompt the UserPromptSubmit
// hooks, as any turn boundary does. Such a compaction reaches the classic
// PreCompact and PostCompact hooks as trigger `manual`, so the session tool's
// compaction gate, which holds only `auto`, lets it through.
//
// A rejected or vetoed compaction is logged and not retried: the marker is
// spent either way, and a stopped turn is continued whatever became of it.
const MARKER = '.session-switch-soon'
const SWITCHED = '.session-login-switch'
const POLL_MS = 5000
const SETTLE_MS = 2000
const WARM_MS = 60 * 60 * 1000
const FLOOR = 200_000
const CONTINUE = 'This turn was paused to compact the conversation ahead of a login switch. Continue where you left off.'

const field = (text: string, key: string) => text.match(new RegExp(`^${key}=(.+)$`, 'm'))?.[1]

type Soon = { login: string; reset: number; writtenAt: number }

export const register = (on: On, loop: MainLoop) => {
  // Shared by the poll and the turn.step hook. `due`: a compaction is pending,
  // the session qualifies and a turn is running, so its next request is
  // stopped. `resume`: a request was stopped, so the turn is continued once it
  // has ended.
  let due = false
  let resume = false

  on('turn.step', async function* ($, e, next) {
    if (e.agentId !== undefined || !due) return yield* next(e)
    due = false
    resume = true
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null } as const
  })

  on('session.start', { isInteractive: true }, async ($, e, next) => {
    const started = await next(e)
    const cfg = (await $.env.get('CLAUDE_CONFIG_DIR')) || `${await $.env.get('HOME')}/.claude`
    // The three variables replace paths and the floor for a throwaway session
    // under test: every running session polls the real markers, so touching
    // them would act on them all. The engine lists the variables a module
    // reads, so each name has to be spelled out here.
    const markerPath = (await $.env.get('SESSION_SWITCH_SOON_MARKER')) || `${cfg}/${MARKER}`
    const switchedPath = (await $.env.get('SESSION_LOGIN_SWITCH_MARKER')) || `${cfg}/${SWITCHED}`
    const floor = Number(await $.env.get('SESSION_PRE_SWITCH_COMPACT_FLOOR')) || FLOOR
    // 0 while there is no file, so a marker first written after the session
    // started counts as new.
    const mtime = (path: string) => $.fs.stat(path).then((s) => s.mtimeMs, () => 0)
    let seen = await mtime(markerPath)
    let lastKey = ''
    let pending: Soon | undefined
    let lastFailure = ''

    $.clock.every(POLL_MS, () => {
      void (async () => {
        const written = await mtime(markerPath)
        if (written !== seen) {
          seen = written
          // With it goes the stop a running turn was due, which no later line
          // of this poll would withdraw.
          if (written === 0) {
            pending = undefined
            due = false
          }
          // A torn or missing file reads as no marker; the next write is seen.
          const text = await $.fs.read(markerPath).catch(() => '')
          const login = field(text, 'login')
          const reset = Number(field(text, 'reset'))
          const key = `${login}|${reset}`
          if (login && reset > 0 && key !== lastKey) {
            lastKey = key
            pending = { login, reset, writtenAt: written }
          }
        }
        if (pending === undefined && !resume) return

        const now = await $.clock.now()
        if (pending !== undefined && (pending.reset * 1000 <= now || (await mtime(switchedPath)) > pending.writtenAt)) {
          pending = undefined
        }
        const tokens = pending === undefined ? 0 : ((await $.session.usage()).context.tokens ?? 0)
        const qualifies = pending !== undefined && tokens >= floor && (loop.busy || now - loop.endedAt < WARM_MS)
        due = qualifies && loop.busy
        if (loop.busy || now - loop.endedAt < SETTLE_MS) return

        const stopped = resume
        resume = false
        if (!qualifies && !stopped) return
        let compacting: Promise<void> | undefined
        const soon = qualifies ? pending : undefined
        if (soon !== undefined) {
          // Cleared before the first await, so an overlapping poll finds nothing.
          pending = undefined
          const resets = new Date(soon.reset * 1000).toISOString().slice(0, 16).replace('T', ' ')
          $.ui.log(`compacting ahead of a login switch off ${soon.login} (its window resets ${resets} UTC)`)
          compacting = $.session.compact().then(
            (result) => {
              if (result.skip !== undefined) $.ui.log(`compaction ahead of a login switch skipped: ${result.skip}`)
            },
            (err: unknown) => {
              $.ui.log(`compaction ahead of a login switch failed: ${String(err)}`)
            },
          )
        }
        if (stopped) {
          // A rejection is a hook's deny or an API that changed, and would be
          // one again on a retry, so it is reported like a drop.
          const submitted = await $.prompt.submit({ text: CONTINUE }).catch((err: unknown) => ({ drop: String(err) }))
          if (submitted.drop !== undefined) $.ui.log(`the turn paused ahead of a login switch was not continued: ${submitted.drop}`)
        }
        await compacting
      })().catch((err: unknown) => {
        // Once for each different failure: one that repeats would otherwise
        // draw a line every poll for as long as a marker is pending.
        const failure = String(err)
        if (failure !== lastFailure) $.ui.log(`the check for a compaction ahead of a login switch failed: ${failure}`)
        lastFailure = failure
      })
    })
    return started
  })
}
