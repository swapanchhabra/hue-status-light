import type { EngineInterface, Register } from 'claude-code'

// Cowork side of hue-status-light. Cowork runs in the cloud or a VM, which
// cannot reach the Hue Bridge, so each event runs ~/.claude/hue/hue-status.sh
// on the Mac linked to the session through the "Control your Mac" osascript
// tool. (Claude Code on the Mac uses the plugin's shell hooks instead.)
// The Mac script merges every Claude Code and Cowork session into one light:
//   steady: purple = a question for you, orange = a permission prompt,
//           red = a test failed (until you reply), dim blue = working,
//           green = all done
//   flash:  5 s at full brightness: purple on a question, orange on a
//           permission prompt, green when a turn finishes, red if a test
//           failed during it
//
// Every hook only observes: it never changes, answers or delays an event,
// and always hands it on unchanged with `return next(e)`.

type Cmd = 'working' | 'question' | 'waiting' | 'tool' | 'fail' | 'done' | 'end'

const SERVER = 'remote-devices'
const TOOL = 'Control_your_Mac__osascript'

const BASH_TOOLS = new Set(['Bash', 'mcp__remote-devices__device_bash'])

const TEST_RE =
  /(^|[;&|\s(])(pytest|py\.test|jest|vitest|mocha|ava|playwright test|cypress run|go test|cargo (test|nextest)|ctest|rspec|phpunit|dotnet test|swift test|tox|nox|(npm|pnpm|yarn|bun)( run)? test([:\s]|$)|npx (jest|vitest|mocha|playwright)|python[0-9.]* -m (pytest|unittest)|(\.\/)?gradlew?[^;&|]* (test|check)|mvn[^;&|]* (test|verify)|xcodebuild[^;&|]* test|make[^;&|]* (test|check))/

const FAIL_RE =
  /(\b[1-9][0-9]* (failed|failing|failures?)\b|^FAIL[\s:]|--- FAIL|test result: FAILED|^FAILED |BUILD FAILURE|Tests run:.*Failures: [1-9])/m

let sessionId = 'cowork'
let blocked = false   // a question or permission prompt is up for this session
let last: { cmd: Cmd; at: number } | undefined
let backoffUntil = 0  // the Mac link was not reachable: retry after a pause
let hinted = false    // told the person once that setup is missing

function send($: EngineInterface, cmd: Cmd) {
  const now = Date.now()
  if ((cmd === 'question' || cmd === 'waiting') && last?.cmd === cmd && now - last.at < 3000) return
  last = { cmd, at: now }
  blocked = cmd === 'question' || cmd === 'waiting'
  if (now < backoffUntil) return
  const sh = `H="$HOME/.claude/hue/hue-status.sh"; [ -x "$H" ] || { echo HUE_NOT_INSTALLED; exit 0; }; echo '{"session_id":"${sessionId}"}' | "$H" ${cmd}`
  const script = `do shell script ${JSON.stringify(sh)}`
  // fire and forget: never hold up the session
  $.mcp
    .call(SERVER, TOOL, { script })
    .then(r => {
      const text = r.content.map(b => ('text' in b ? String(b.text) : '')).join(' ')
      if (!hinted && text.includes('HUE_NOT_INSTALLED')) {
        hinted = true
        $.ui.toast('Hue status light is not set up on your Mac yet: run /hue-setup')
      }
    })
    .catch(() => {
      // no linked Mac (or a Claude Code session, where the plugin's shell hooks do the work)
      backoffUntil = Date.now() + 60_000
    })
}

function commandOf(input: unknown): string {
  if (input && typeof input === 'object' && 'command' in input) {
    const c = (input as { command?: unknown }).command
    if (typeof c === 'string') return c
  }
  return ''
}

function textOf(value: unknown): string {
  if (typeof value === 'string') return value
  if (value && typeof value === 'object') {
    const o = value as { stdout?: unknown; stderr?: unknown; content?: unknown }
    const parts = [o.stdout, o.stderr].filter((p): p is string => typeof p === 'string')
    if (Array.isArray(o.content)) {
      for (const b of o.content) {
        if (b && typeof b === 'object' && typeof (b as { text?: unknown }).text === 'string') parts.push((b as { text: string }).text)
      }
    }
    return parts.join('\n')
  }
  return ''
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    try {
      const id = await $.session.id()
      sessionId = 'cowork-' + String(id).replace(/[^A-Za-z0-9_-]/g, '')
    } catch {}
    return next(e)
  })

  // You sent a message: busy again, and this session's red reminder clears.
  on('prompt.submit', ($, e, next) => {
    try {
      send($, 'working')
    } catch {}
    return next(e)
  })

  // End of each main-loop turn: green flash, or red flash if a test failed.
  on('turn.complete', ($, e, next) => {
    try {
      if (!e.agentId) send($, 'done')
    } catch {}
    return next(e)
  })

  on('session.end', ($, e, next) => {
    try {
      send($, 'end')
    } catch {}
    return next(e)
  })

  // Purple while Claude waits for your answer to a question.
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e, next) => {
    try {
      send($, 'question')
    } catch {}
    return next(e)
  })

  // Orange while a permission prompt waits for you.
  on('classic.PermissionRequest', ($, e, next) => {
    try {
      if (e.tool_name !== 'AskUserQuestion') send($, 'waiting')
    } catch {}
    return next(e)
  })

  on('classic.Notification', ($, e, next) => {
    try {
      if (e.notification_type === 'permission_prompt') send($, 'waiting')
      else if (e.notification_type === 'elicitation_dialog') send($, 'question')
    } catch {}
    return next(e)
  })

  // A tool finished: unblock if it had waited for you; red on a failed test.
  on('classic.PostToolUse', ($, e, next) => {
    try {
      if (blocked) send($, 'tool')
      if (BASH_TOOLS.has(e.tool_name) && TEST_RE.test(commandOf(e.tool_input)) && FAIL_RE.test(textOf(e.tool_response))) {
        send($, 'fail')
      }
    } catch {}
    return next(e)
  })

  on('classic.PostToolUseFailure', ($, e, next) => {
    try {
      if (blocked) send($, 'tool')
      if (BASH_TOOLS.has(e.tool_name) && TEST_RE.test(commandOf(e.tool_input)) && !e.is_interrupt) {
        send($, 'fail')
      }
    } catch {}
    return next(e)
  })
}
