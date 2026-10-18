import type { Register } from 'claude-code'
import { register as reloadOnSwitch } from './reload-on-switch'
import { register as rateLimitMenu } from './rate-limit-menu'

// A plugin names one hooks module (`claude plugin validate` refuses a second
// hooks.json entry), so this one registers each concern's module, and each
// keeps its own file and its own comment.
export const register: Register = (on, options) => {
  reloadOnSwitch(on, options)
  rateLimitMenu(on, options)
}
