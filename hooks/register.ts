import type { Register } from 'claude-code'
import { followMainLoop, newMainLoop } from './main-loop'
import { register as reloadOnSwitch } from './reload-on-switch'
import { register as rateLimitMenu } from './rate-limit-menu'

// A plugin names one hooks module (`claude plugin validate` refuses a second
// hooks.json entry), so this one registers each concern's module, and each
// keeps its own file and its own comment. Both read the main loop's turns,
// which one plugin may hook only once, so main-loop.ts follows them for both.
export const register: Register = (on) => {
  const loop = newMainLoop()
  followMainLoop(on, loop)
  reloadOnSwitch(on, loop)
  rateLimitMenu(on, loop)
}
