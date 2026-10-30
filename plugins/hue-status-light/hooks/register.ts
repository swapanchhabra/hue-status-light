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

type Cmd = 'working' | 'question' | 'waiting' | 'tool' | 'fail' | 'done' | 'end'

const SERVER = 'remote-devices'
const TOOL = 'Control_your_Mac__osascript'

const BASH_TOOLS = new Set(['Bash', 'mcp__remote-devices__device_bash'])

const TEST_RE =
  /(^|[;&|\s(])(pytest|py\.test|jest|vitest|mocha|ava|playwright test|cypress run|go test|cargo (test|nextest)|ctest|rspec|phpunit|dotnet test|swift test|tox|nox|(npm|pnpm|yarn|bun)( run)? test([:\s]|$)|npx (jest|vitest|mocha|playwright)|python[0-9.]* -m (pytest|unittest)|(\.\/)?gradlew?[^;&|]* (test|check)|mvn[^;&|]* (test|verify)|xcodebuild[^;&|]* test|make[^;&|]* (test|check))/

const FAIL_RE =
  /(\b[1-9][0-9]* (failed|failing|failures?)\b|^FAIL[\s:]|--- FAIL|test result: FAILED|^FAILED |BUILD FAILURE|Tests run:.*Failures: [1-9])/m

const INTERRUPT_RE = /interrupted by user|was interrupted|user (aborted|cancelled)/i

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
    send($, 'working')
    return next(e)
  }).catch(($, e, next) => next(e))

  // End of each main-loop turn: green flash, or red flash if a test failed.
  on('turn.complete', async ($, e, next) => {
    const r = await next(e)
    if (!e.agentId) send($, 'done')
    return r
  })

  on('session.end', async ($, e, next) => {
    send($, 'end')
    return next(e)
  })

  // Orange while a tool call waits for your approval.
  on('tool.check', async ($, e, next) => {
    const r = await next(e)
    if (r.decision === 'ask' && e.approver !== undefined && e.tool !== 'AskUserQuestion') send($, 'waiting')
    return r
  }).catch(($, e, next) => next(e))

  // Purple while Claude waits for your answer to a question.
  on('tool.call', { tool: 'AskUserQuestion' }, async ($, e, next) => {
    send($, 'question')
    const r = await next(e)
    send($, 'tool')
    return r
  }).catch(($, e, next) => next(e))

  // After any other tool: unblock if it had waited for you; red on a failed test.
  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    if (e.tool === 'AskUserQuestion') return ran
    if (blocked) send($, 'tool')
    if (!BASH_TOOLS.has(e.tool)) return ran
    const cmd = typeof (e as any).command === 'string' ? (e as any).command : ''
    if (!TEST_RE.test(cmd) || ran.deny !== undefined) return ran
    const out = ran.text ?? ''
    if (INTERRUPT_RE.test(out)) return ran
    if (ran.isError === true || FAIL_RE.test(out)) send($, 'fail')
    return ran
  }).catch(($, e, next) => next(e))
}
