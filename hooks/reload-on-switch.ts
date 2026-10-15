import type { Register } from 'claude-code'

// After `session account use` or an automatic switch, make this session fetch
// its claude.ai connectors again, from the login now live.
//
// A session fetches its connector list once, when it starts, from the login
// live then, and every login has its own connector ids. The token swap reaches
// a running session on its next request, but its connectors keep the old
// login's ids: the connector proxy answers them 404, and Claude Code reads that
// as an expired MCP session, on every call until the session ends.
// /reload-plugins fetches the list again from the live login and moves each
// connector to its new id. It is a whole reload of the session's plugins,
// skills, agents and hooks; background shells and background subagents keep
// running through it. Not checked: whether a subagent already running at the
// switch gets the new connectors.
//
// The signal is the mtime of the marker the swap writes once it has read the
// new credential back (acct_swap in the CLI); the login name inside is for a
// person reading the file. Not .claude.json, which a running session rewrites
// from memory with the login it started on. The marker's name is shared with
// acct_swap, which ships in the clone while this ships in the plugin, so a
// rename strands sessions running an older plugin copy.
//
// $.command.run queues the reload until the session is idle, so a turn under
// way at the switch keeps failing its connector calls until it ends. A reload
// keeps this module as loaded unless its code changed, so `seen` is set before
// the reload is queued: set after it, a reload that keeps failing would be
// tried again on every poll. Where the code did change, the fresh copy reads
// the marker at its own start. Either way each switch reloads once.
//
// Two shorter routes did not work when tested. MCP_DISCOVERY_CACHE=1 arms
// Claude Code's own login-change watcher, but the watcher reads the identity a
// running session keeps in memory and did not see an outside swap. Writing
// /reload-plugins to the session's message socket (where other sessions'
// messages arrive) delivers it as a message to the model, which cannot run
// built-in commands. Everything above was observed on Claude Code 2.1.300; it
// rests on internals (one connector list per process, the reload re-fetching
// it), so recheck it by switching logins under a live session when Claude Code
// changes how it loads claude.ai connectors.
const MARKER = '.session-login-switch'
const POLL_MS = 5000

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const cfg = (await $.env.get('CLAUDE_CONFIG_DIR')) || `${await $.env.get('HOME')}/.claude`
    const path = `${cfg}/${MARKER}`
    // 0 while there is no marker, so the first one ever written is a switch too.
    const mtime = () => $.fs.stat(path).then((s) => s.mtimeMs, () => 0)
    let seen = await mtime()
    $.clock.every(POLL_MS, () => {
      void mtime().then(async (now) => {
        if (now === seen) return
        seen = now
        await $.command.run({ command: 'reload-plugins' })
      }).catch((err: unknown) => {
        $.ui.log(`session: /reload-plugins after a login switch failed: ${String(err)}`)
      })
    })
    return started
  })
}
