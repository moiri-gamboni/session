import type { On } from 'claude-code'

// The main loop's turns, followed once for every module of the plugin: the
// engine refuses a second hook on an event without a matcher in one plugin.
export type MainLoop = {
  // A main-loop turn is running.
  busy: boolean
  // When the last main-loop turn ended, on the engine's clock; 0 before any.
  endedAt: number
  // When the last main-loop turn ended on an API error, until a module that
  // acts on it clears it.
  diedAt: number | undefined
}

export const newMainLoop = (): MainLoop => ({ busy: false, endedAt: 0, diedAt: undefined })

export const followMainLoop = (on: On, loop: MainLoop) => {
  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) loop.busy = true
    return next(e)
  })
  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      loop.busy = false
      loop.endedAt = await $.clock.now()
      if (e.reason === 'error') loop.diedAt = loop.endedAt
    }
    return next(e)
  })
}
