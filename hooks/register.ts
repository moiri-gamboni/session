import type { Register } from 'claude-code'
import { register as reloadOnSwitch } from './reload-on-switch'
import { register as rateLimitMenu } from './rate-limit-menu'

// The plugin's one hooks module (hooks.json names one), so each concern keeps
// its own file and its own comment.
export const register: Register = (on, options) => {
  reloadOnSwitch(on, options)
  rateLimitMenu(on, options)
}
