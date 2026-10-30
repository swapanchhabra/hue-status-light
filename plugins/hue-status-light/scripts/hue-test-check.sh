#!/bin/bash
# Claude Code PostToolUse / PostToolUseFailure hook for Bash.
# Marks the session "fail" (red) only when the command looks like a test run
# AND it failed: a non-zero exit, or failure text in the output.
# Needs jq (built into macOS 15+); without it, failed tests are not detected.
# Always exits 0 so it never blocks Claude.

HERE="$(cd "$(dirname "$0")" && pwd)"
INPUT="$(cat 2>/dev/null)"
[ -n "$INPUT" ] || exit 0
JQ="$(command -v jq || true)"
[ -n "$JQ" ] || exit 0

EVENT="$(printf '%s' "$INPUT" | "$JQ" -r '.hook_event_name // empty' 2>/dev/null)"
CMD="$(printf '%s' "$INPUT"   | "$JQ" -r '.tool_input.command // empty' 2>/dev/null)"
[ -n "$CMD" ] || exit 0

# 1) Is this a test run?
TEST_RE='(^|[;&|[:space:](])(pytest|py\.test|jest|vitest|mocha|ava|playwright test|cypress run|go test|cargo (test|nextest)|ctest|rspec|phpunit|dotnet test|swift test|tox|nox|(npm|pnpm|yarn|bun)( run)? test([:[:space:]]|$)|npx (jest|vitest|mocha|playwright)|python[0-9.]* -m (pytest|unittest)|(\./)?gradlew?[^;&|]* (test|check)|mvn[^;&|]* (test|verify)|xcodebuild[^;&|]* test|make[^;&|]* (test|check))'
printf '%s' "$CMD" | grep -Eq "$TEST_RE" || exit 0

# 2) Did it fail?
FAILED=0
if [ "$EVENT" = "PostToolUseFailure" ]; then
  # Non-zero exit. Ignore user interrupts (Esc / Ctrl-C).
  INTR="$(printf '%s' "$INPUT" | "$JQ" -r '.is_interrupt // false' 2>/dev/null)"
  [ "$INTR" = "true" ] || FAILED=1
else
  # Exit 0, but the output may still report failures (e.g. `pytest | tail`).
  OUT="$(printf '%s' "$INPUT" | "$JQ" -r '[.tool_response.stdout?, .tool_response.stderr?, (.tool_response|strings)?] | map(select(.)) | join("\n")' 2>/dev/null)"
  FAIL_RE='(\b[1-9][0-9]* (failed|failing|failures?)\b|^FAIL[[:space:]:]|--- FAIL|test result: FAILED|^FAILED |BUILD FAILURE|Tests run:.*Failures: [1-9])'
  printf '%s' "$OUT" | grep -Eq "$FAIL_RE" && FAILED=1
fi

[ "$FAILED" = "1" ] && printf '%s' "$INPUT" | "$HERE/hue-status.sh" fail
exit 0
