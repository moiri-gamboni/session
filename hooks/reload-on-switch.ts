import type { On } from 'claude-code'
import type { MainLoop } from './main-loop'

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
// new credential back (acct_swap in the CLI). Not .claude.json, which a running
// session rewrites from memory with the login it started on. The marker's name
// is shared with acct_swap, which ships in the clone while this ships in the
// plugin, so a rename strands sessions running an older plugin copy. Such a
// copy reads only the mtime, which is why the marker's content can change
// without stranding it.
//
// The marker's lines say which login the box moved from and to and why
// (from=, to=, reason=). They become the arguments of the reload command:
// /reload-plugins ignores its arguments, and Claude Code draws a plugin-run
// command row as typed, so the one row reads "/reload-plugins login switched
// from A to B (5h limit)" above the reload's own "Reloaded: ..." line. That is
// one note per switch, drawn by Claude Code and not written by the model; the
// model reads it too, as the command's arguments. A separate notice would be a
// second row: $.ui.log draws a dim "● session: ..." line, and $.session.append
// with a system row is stored but drawn only in the detailed transcript
// (ctrl+o). A marker without the lines, or one that cannot be read, reloads
// without a note: the reload is the point. Observed on Claude Code 2.1.301.
//
// $.command.run queues the reload until the session is idle, so a turn under
// way at the switch keeps failing its connector calls until it ends. A command
// queued during a turn is drawn under the conversation ("Prompt from the
// session plugin") until it runs, and in a session its work keeps busy, with
// notifications and typed prompts taking the queue's turn ahead of it, that
// can be most of an hour. So a switch seen during a turn is held here, and the
// reload is queued at the first poll that finds the main loop idle for
// SETTLE_MS: long enough not to land between two queued turns, which follow
// each other within milliseconds. Two switches in one busy stretch reload once,
// with the later note. A reload keeps this module as loaded unless its code
// changed, so `seen` is set before the reload is queued: set after it, a
// reload that keeps failing would be tried again on every poll. Where the code
// did change, the fresh copy reads the marker at its own start. Either way each
// switch reloads once.
//
// Two shorter routes did not work when tested. MCP_DISCOVERY_CACHE=1 arms
// Claude Code's own login-change watcher, but the watcher reads the identity a
// running session keeps in memory and did not see an outside swap. Writing
// /reload-plugins to the session's message socket (where other sessions'
// messages arrive) delivers it as a message to the model, which cannot run
// built-in commands. The connector behaviour above was observed on Claude Code
// 2.1.300; it rests on internals (one connector list per process, the reload
// re-fetching it), so recheck it by switching logins under a live session when
// Claude Code changes how it loads claude.ai connectors.
const MARKER = '.session-login-switch'
const POLL_MS = 5000
const SETTLE_MS = 2000

const field = (text: string, key: string) => text.match(new RegExp(`^${key}=(.+)$`, 'm'))?.[1]

export const register = (on: On, loop: MainLoop) => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    const cfg = (await $.env.get('CLAUDE_CONFIG_DIR')) || `${await $.env.get('HOME')}/.claude`
    // SESSION_LOGIN_SWITCH_MARKER replaces the path for a throwaway session
    // under test: every running session polls the real marker, so touching it
    // reloads them all. The engine lists the variables a module reads, so the
    // name has to be spelled out here.
    const path = (await $.env.get('SESSION_LOGIN_SWITCH_MARKER')) || `${cfg}/${MARKER}`
    // 0 while there is no marker, so the first one ever written is a switch too.
    const mtime = () => $.fs.stat(path).then((s) => s.mtimeMs, () => 0)
    let seen = await mtime()
    // The reload a switch asked for and the idle main loop has not run yet:
    // its note, '' for none.
    let pending: string | undefined
    $.clock.every(POLL_MS, () => {
      void (async () => {
        const now = await mtime()
        if (now !== seen) {
          seen = now
          // Reads the marker only after its mtime moved, and a torn or missing
          // file costs the note, never the reload.
          const text = await $.fs.read(path).catch(() => '')
          const [from, to, why] = [field(text, 'from'), field(text, 'to'), field(text, 'reason')]
          pending = from && to && why ? `login switched from ${from} to ${to} (${why})` : ''
        }
        if (pending === undefined || loop.busy || (await $.clock.now()) - loop.endedAt < SETTLE_MS) return
        const note = pending
        pending = undefined
        await $.command.run(note ? { command: 'reload-plugins', args: note } : { command: 'reload-plugins' })
      })().catch((err: unknown) => {
        $.ui.log(`session: /reload-plugins after a login switch failed: ${String(err)}`)
      })
    })
    return started
  })
}
