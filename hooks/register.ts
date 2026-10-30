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
// Off unless you turn on the plugin option `cowork_mac_light`: only then does
// the module call the osascript tool on your Mac, and it registers no hooks
// at all otherwise.
//
// Every hook only observes: it never changes, answers or blocks an event.
// Hooks hand their event on unchanged with `return next(e)`; the one that
// needs a tool's result awaits next(e) and returns that result untouched.

type Cmd = 'working' | 'question' | 'waiting' | 'tool' | 'fail' | 'done' | 'idle' | 'end'

const SERVER = 'remote-devices'
const TOOL = 'Control_your_Mac__osascript'

const BASH_TOOLS = new Set(['Bash', 'mcp__remote-devices__device_bash'])

// Only a test tool in command position counts (after ; & | ( or a wrapper like
// `uv run` / `npx`), so `which pytest` or `pip install pytest` do not. POSIX
// classes so it stays identical to TEST_RE in scripts/hue-status.sh.
const TEST_SRC = '(^|[;&|(])[[:space:]]*(([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*|env|time|command|exec|nice|sudo|xvfb-run( -a)?|timeout [0-9.]+[smhd]?|npx|pnpx|bunx|bun x|pnpm|yarn|uv run|poetry run|pipenv run|pdm run|hatch run|rye run|bundle exec)[[:space:]]+)*([^[:space:];&|()]*/)?(pytest|py\.test|jest|vitest|mocha|ava|playwright test|cypress run|go test|cargo (test|nextest)|ctest|rspec|phpunit|dotnet test|swift test|tox|nox|(npm|pnpm|yarn|bun)( run)? test([:-][^[:space:];&|]*)?|python[0-9.]* -m (pytest|unittest)|gradlew?([[:space:]][^;&|]*)?[[:space:]:](test|check)[^[:space:];&|]*|mvnw?([[:space:]][^;&|]*)? (test|verify)|xcodebuild([[:space:]][^;&|]*)? test|make([[:space:]][^;&|]*)? (test|check)[^[:space:];&|]*)([[:space:];&|)]|$)'
const TEST_RE = new RegExp(TEST_SRC.replaceAll('[:space:]', '\\s'), 'm')

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

function commandOf(input: unknown): string {
  if (input && typeof input === 'object' && 'command' in input) {
    const c = (input as { command?: unknown }).command
    if (typeof c === 'string') return c
  }
  return ''
}

export const register: Register = (on, options) => {
  if (options.cowork_mac_light !== true) return

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
  // A turn you interrupted or that an error ended settles without a flash,
  // as in Claude Code (where Stop does not fire for those).
  on('turn.complete', ($, e, next) => {
    try {
      if (!e.agentId) send($, e.reason === 'answer' ? 'done' : 'idle')
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
  // Watches the result only; the call and its result go on unchanged.
  on('tool.call', async ($, e, next) => {
    const ran = await next(e)
    try {
      if (blocked) send($, 'tool')
      if (BASH_TOOLS.has(e.tool) && ran.deny === undefined && TEST_RE.test(commandOf(e))) {
        const out = ran.text ?? ''
        if (!INTERRUPT_RE.test(out) && (ran.isError === true || FAIL_RE.test(out))) send($, 'fail')
      }
    } catch {}
    return ran
  })
}
