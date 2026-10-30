// Checks that the Cowork module and the shell script use the same test-run
// pattern, and that the JavaScript form classifies tests/commands.txt.
// Usage: node tests/patterns.test.mjs <cowork module> <shell script>
// The caller passes both paths (CI does), so this file names neither.
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const [modulePath, scriptPath] = process.argv.slice(2)
if (!modulePath || !scriptPath) {
  console.log('usage: node tests/patterns.test.mjs <cowork module> <shell script>')
  process.exit(2)
}
const ts = readFileSync(modulePath, 'utf8')
const sh = readFileSync(scriptPath, 'utf8')
const tsSrc = ts.match(/^const TEST_SRC = '([^']*)'$/m)?.[1]
const shSrc = sh.match(/^\s*TEST_RE='([^']*)'$/m)?.[1]

let failed = 0
const check = (ok, msg) => { if (!ok) { failed++; console.log('FAIL ' + msg) } }

check(tsSrc && shSrc, 'found TEST_SRC in the module and TEST_RE in the script')
check(tsSrc === shSrc, 'module TEST_SRC equals script TEST_RE')

const re = new RegExp(tsSrc.replaceAll('[:space:]', '\\s'), 'm')
const cases = readFileSync(fileURLToPath(new URL('commands.txt', import.meta.url)), 'utf8')
  .split('\n').filter(l => l && !l.startsWith('#'))
for (const line of cases) {
  const [want, cmd] = line.split('\t')
  check(re.test(cmd) === (want === 'yes'), `js: expected ${want} for: ${cmd}`)
}

console.log(failed ? `${failed} failed` : `ok: ${cases.length} commands`)
process.exit(failed ? 1 : 0)
