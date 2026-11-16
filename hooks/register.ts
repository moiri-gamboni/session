import type { Register } from 'claude-code'
import { followMainLoop, newMainLoop } from './main-loop'
import { register as reloadOnSwitch } from './reload-on-switch'
import { register as rateLimitMenu } from './rate-limit-menu'
import { register as compactBeforeSwitch } from './compact-before-switch'

// A plugin names one hooks module (`claude plugin validate` refuses a second
// hooks.json entry), so this one registers each concern's module, and each
// keeps its own file and its own comment. They read the main loop's turns,
// which one plugin may hook only once, so main-loop.ts follows them for all.
export const register: Register = (on) => {
  const loop = newMainLoop()
  followMainLoop(on, loop)
  reloadOnSwitch(on, loop)
  rateLimitMenu(on, loop)
  compactBeforeSwitch(on, loop)
}
