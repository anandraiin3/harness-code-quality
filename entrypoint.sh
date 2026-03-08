#!/bin/bash
# Harness CI Plugin: AI Code Quality Scanner
# Supports: OpenAI, Anthropic (Claude), Google Gemini
#
# PLUGIN INPUTS (set as Plugin step settings in Harness):
#   PLUGIN_LLM_PROVIDER       - openai | anthropic | gemini  (default: openai)
#   PLUGIN_API_KEY            - API key for the chosen provider (required)
#   PLUGIN_MODEL              - Model name (optional, defaults per provider)
#   PLUGIN_SOURCE_DIR         - Root workspace directory (default: current working dir)
#   PLUGIN_SCAN_PATHS         - Comma-separated files/folders to scan, relative to
#                               SOURCE_DIR or absolute. When omitted, the entire
#                               SOURCE_DIR is scanned.
#                               Examples:
#                                 src/api,src/models          ← two folders
#                                 src/auth/login.py           ← single file
#                                 src/api,tests/unit/auth.py  ← mixed
#   PLUGIN_FILE_EXTENSIONS    - Comma-separated extensions to include when scanning
#                               directories (default: cs,py,js,ts,java).
#                               Ignored for explicitly listed files in SCAN_PATHS.
#   PLUGIN_MAX_FILES          - Max source files to collect (default: 20)
#   PLUGIN_MAX_CHARS          - Max characters of code to send (default: 100000)
#   PLUGIN_FAIL_ON_CRITICAL   - Exit non-zero if critical_issues > 0 (default: true)
#   PLUGIN_FAIL_ON_SEVERITY   - Exit non-zero if severity is at or above this level.
#                               Values: critical | high | medium | none  (default: high)
#                               'high' = fail on high or critical severity
#                               'none' = disable severity check
#
# QUALITY GATE THRESHOLDS (fail the step if the metric falls below / exceeds):
#   Score minimums (0-10 float; set to 0 to disable that check):
#   PLUGIN_MIN_OVERALL_SCORE          - default: 6  (SonarQube "C" grade equivalent)
#   PLUGIN_MIN_SECURITY_SCORE         - default: 7  (OWASP ASVS L1 / PCI-DSS req 6)
#   PLUGIN_MIN_RELIABILITY_SCORE      - default: 7  (SRE / SLA practices)
#   PLUGIN_MIN_MAINTAINABILITY_SCORE  - default: 6  (SonarQube "B" grade equivalent)
#   PLUGIN_MIN_PERFORMANCE_SCORE      - default: 6  (Google SRE load-testing baseline)
#   PLUGIN_MIN_TESTABILITY_SCORE      - default: 5  (N/A scores are automatically skipped)
#   PLUGIN_MIN_COMPLEXITY_SCORE       - default: 5  (N/A scores are automatically skipped)
#   PLUGIN_MIN_DUPLICATION_SCORE      - default: 6  (N/A scores are automatically skipped)
#
#   Count maximums (-1 to disable that check):
#   PLUGIN_MAX_CODE_SMELLS            - default: -1 (disabled; 10 is a reasonable gate)
#   PLUGIN_MAX_DEBT_HOURS             - default: -1 (disabled; 16 ≈ 2 working days)
#   PLUGIN_MAX_FINDINGS_COUNT         - default: -1 (disabled; 10 is a reasonable gate)
#
#   PLUGIN_TIMEOUT_SECONDS    - Max seconds to wait for a single LLM API response (default: 300)
#                               Increase for large codebases / slow providers.
#                               The models-listing call always uses a 10 s hard limit.
#   PLUGIN_RETRY_COUNT        - Number of additional attempts after a timeout or network error
#                               (default: 2 → up to 3 total attempts, with 15 s / 30 s backoff)
#
#   PLUGIN_PROMPT_PRESET      - Built-in analysis profile (default: standard)
#                               standard     - Balanced sweep: maintainability, security,
#                                              performance, reliability, overall score
#                               security     - OWASP/CVE deep-dive; adds severity +
#                                              vulnerabilities_count
#                               tech-debt    - Maintainability focus; adds duplication,
#                                              complexity, debt_hours_estimate
#                               full-audit   - Complete report; all scores + testability,
#                                              top_finding, top_recommendation
#   PLUGIN_CUSTOM_PROMPT      - Override the entire prompt with your own text.
#                               When set, PLUGIN_PROMPT_PRESET is ignored.
#                               Your prompt MUST instruct the LLM to return JSON.
#                               Include the expected JSON schema in your prompt.
#
# OUTPUTS (written to $DRONE_OUTPUT, scoped to Pipeline in Harness):
#   PROMPT_PRESET, MAINTAINABILITY_SCORE, SECURITY_SCORE, PERFORMANCE_SCORE,
#   RELIABILITY_SCORE, TESTABILITY_SCORE, COMPLEXITY_SCORE, DUPLICATION_SCORE,
#   OVERALL_SCORE, CODE_SMELLS, CRITICAL_ISSUES, SEVERITY,
#   DEBT_HOURS_ESTIMATE, FINDINGS_COUNT, TOP_FINDING, TOP_RECOMMENDATION, SUMMARY

set -e

# ---------------------------------------------------------------------------
# Read inputs
# ---------------------------------------------------------------------------
PROVIDER="${PLUGIN_LLM_PROVIDER:-openai}"
API_KEY="$(echo "${PLUGIN_API_KEY:-}" | tr -d '[:space:]')"
MODEL="${PLUGIN_MODEL:-}"
SOURCE_DIR="${PLUGIN_SOURCE_DIR:-$(pwd)}"
SCAN_PATHS="${PLUGIN_SCAN_PATHS:-}"          # empty = scan full SOURCE_DIR
FILE_EXTS="${PLUGIN_FILE_EXTENSIONS:-cs,py,js,ts,java}"
MAX_FILES="${PLUGIN_MAX_FILES:-20}"
MAX_CHARS="${PLUGIN_MAX_CHARS:-100000}"
FAIL_ON_CRITICAL="${PLUGIN_FAIL_ON_CRITICAL:-true}"
FAIL_ON_SEVERITY="${PLUGIN_FAIL_ON_SEVERITY:-high}"

# Score minimums — 0 disables the check; N/A values are always skipped
MIN_OVERALL_SCORE="${PLUGIN_MIN_OVERALL_SCORE:-6}"
MIN_SECURITY_SCORE="${PLUGIN_MIN_SECURITY_SCORE:-7}"
MIN_RELIABILITY_SCORE="${PLUGIN_MIN_RELIABILITY_SCORE:-7}"
MIN_MAINTAINABILITY_SCORE="${PLUGIN_MIN_MAINTAINABILITY_SCORE:-6}"
MIN_PERFORMANCE_SCORE="${PLUGIN_MIN_PERFORMANCE_SCORE:-6}"
MIN_TESTABILITY_SCORE="${PLUGIN_MIN_TESTABILITY_SCORE:-5}"
MIN_COMPLEXITY_SCORE="${PLUGIN_MIN_COMPLEXITY_SCORE:-5}"
MIN_DUPLICATION_SCORE="${PLUGIN_MIN_DUPLICATION_SCORE:-6}"

# Count maximums — -1 disables the check; N/A values are always skipped
MAX_CODE_SMELLS="${PLUGIN_MAX_CODE_SMELLS:--1}"
MAX_DEBT_HOURS="${PLUGIN_MAX_DEBT_HOURS:--1}"
MAX_FINDINGS_COUNT="${PLUGIN_MAX_FINDINGS_COUNT:--1}"

TIMEOUT_SECONDS="${PLUGIN_TIMEOUT_SECONDS:-300}"
RETRY_COUNT="${PLUGIN_RETRY_COUNT:-2}"
PROMPT_PRESET="${PLUGIN_PROMPT_PRESET:-standard}"
CUSTOM_PROMPT="${PLUGIN_CUSTOM_PROMPT:-}"

# ---------------------------------------------------------------------------
# Validate required inputs
# ---------------------------------------------------------------------------
case "$PROVIDER" in
  openai|anthropic|gemini) ;;
  *)
    echo "ERROR: Unknown PLUGIN_LLM_PROVIDER '$PROVIDER'."
    echo "       Valid values: openai | anthropic | gemini"
    exit 1
    ;;
esac

if [ -z "$API_KEY" ]; then
  echo ""
  echo "ERROR: PLUGIN_API_KEY is required but was not provided."
  echo ""
  echo "  The plugin needs an API key to call the '$PROVIDER' LLM."
  echo ""
  case "$PROVIDER" in
    openai)
      echo "  → Get your OpenAI API key at: https://platform.openai.com/api-keys"
      echo "  → Recommended Harness secret name: org.OPENAI_API_KEY"
      ;;
    anthropic)
      echo "  → Get your Anthropic API key at: https://console.anthropic.com/settings/keys"
      echo "  → Recommended Harness secret name: org.ANTHROPIC_API_KEY"
      ;;
    gemini)
      echo "  → Get your Gemini API key at: https://aistudio.google.com/app/apikey"
      echo "  → Recommended Harness secret name: org.GEMINI_API_KEY"
      ;;
  esac
  echo ""
  echo "  Once you have the key, store it in Harness:"
  echo "    Organization Settings → Secrets → + New Secret → Secret Text"
  echo ""
  echo "  Then set the plugin setting in your pipeline:"
  echo "    api_key: <+secrets.getValue(\"org.YOUR_SECRET_NAME\")>"
  echo ""
  exit 1
fi

# Warn if the API key format looks wrong for the chosen provider.
# These are non-fatal — key formats can change; this just helps catch
# obvious mismatches (e.g. an OpenAI key used with anthropic provider).
case "$PROVIDER" in
  openai)
    case "$API_KEY" in
      sk-*) ;;
      *)
        echo "WARNING: PLUGIN_API_KEY does not look like an OpenAI key (expected prefix: sk-)."
        echo "         Continuing anyway — double-check your secret if the call fails."
        ;;
    esac
    ;;
  anthropic)
    case "$API_KEY" in
      sk-ant-*) ;;
      *)
        echo "WARNING: PLUGIN_API_KEY does not look like an Anthropic key (expected prefix: sk-ant-)."
        echo "         Continuing anyway — double-check your secret if the call fails."
        ;;
    esac
    ;;
  gemini)
    # Gemini keys have no fixed prefix — skip format check
    ;;
esac

if [ -z "$CUSTOM_PROMPT" ]; then
  case "$PROMPT_PRESET" in
    standard|security|tech-debt|full-audit) ;;
    *)
      echo "ERROR: Unknown PLUGIN_PROMPT_PRESET '$PROMPT_PRESET'."
      echo "       Valid values: standard | security | tech-debt | full-audit"
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Collect source files
# ---------------------------------------------------------------------------
echo "==> Workspace:  $SOURCE_DIR"
echo "    Provider:   $PROVIDER"
echo "    Extensions: $FILE_EXTS"

# Build find -name args dynamically from comma-separated extension list
IFS=',' read -ra EXTS <<< "$FILE_EXTS"
FIND_NAME_ARGS=()
for i in "${!EXTS[@]}"; do
  ext="${EXTS[$i]// /}"
  if [ "$i" -gt 0 ]; then
    FIND_NAME_ARGS+=(-o)
  fi
  FIND_NAME_ARGS+=(-name "*.${ext}")
done

# Resolve a path: absolute paths are used as-is; relative paths are
# joined with SOURCE_DIR.
resolve_path() {
  local p="$1"
  p="${p// /}"          # trim spaces
  if [[ "$p" == /* ]]; then
    echo "$p"
  else
    echo "$SOURCE_DIR/$p"
  fi
}

# Emit file paths for a single scan target (file or directory)
files_for_target() {
  local target
  target=$(resolve_path "$1")

  if [ ! -e "$target" ]; then
    echo "WARNING: Scan path not found, skipping: $target" >&2
    return
  fi

  if [ -f "$target" ]; then
    # Explicitly named file — include regardless of extension filter
    echo "$target"
  elif [ -d "$target" ]; then
    # Directory — apply extension filter and standard exclusions
    find "$target" \
      -type f \
      \( "${FIND_NAME_ARGS[@]}" \) \
      ! -path "*/bin/*" \
      ! -path "*/obj/*" \
      ! -path "*/.git/*" \
      ! -path "*/node_modules/*" \
      ! -path "*/.venv/*"
  fi
}

# Decide what to scan
if [ -n "$SCAN_PATHS" ]; then
  echo "    Scan paths: $SCAN_PATHS"
  IFS=',' read -ra PATH_LIST <<< "$SCAN_PATHS"
  # Collect files from each path into a single list, then apply MAX_FILES cap
  FILE_LIST=()
  for scan_target in "${PATH_LIST[@]}"; do
    while IFS= read -r f; do
      FILE_LIST+=("$f")
    done < <(files_for_target "$scan_target")
  done

  if [ "${#FILE_LIST[@]}" -eq 0 ]; then
    echo "WARNING: No files matched the provided scan paths. Proceeding with empty code block."
    CODE=""
  else
    CODE=$(printf '%s\n' "${FILE_LIST[@]}" \
      | head -n "$MAX_FILES" \
      | xargs cat 2>/dev/null \
      | head -c "$MAX_CHARS" || true)
    echo "    Files found: ${#FILE_LIST[@]} (capped at $MAX_FILES)"
  fi
else
  echo "    Scan paths: <entire workspace>"
  CODE=$(find "$SOURCE_DIR" \
    -type f \
    \( "${FIND_NAME_ARGS[@]}" \) \
    ! -path "*/bin/*" \
    ! -path "*/obj/*" \
    ! -path "*/.git/*" \
    ! -path "*/node_modules/*" \
    ! -path "*/.venv/*" \
    | head -n "$MAX_FILES" \
    | xargs cat 2>/dev/null \
    | head -c "$MAX_CHARS" || true)
fi

if [ -z "$CODE" ]; then
  echo "WARNING: No matching source files found. Proceeding with empty code block."
fi

# ---------------------------------------------------------------------------
# Build the analysis prompt
# ---------------------------------------------------------------------------

# Scoring rubric embedded in every preset so the LLM applies scores consistently
SCORING_GUIDE='Scoring guide (apply strictly and consistently):
  10 = exemplary, production-grade, nothing to improve
  8-9 = good, minor issues only
  5-7 = acceptable but needs improvement
  2-4 = significant problems that should be fixed
  0-1 = critical failures, immediate attention required'

# JSON output rule appended to every prompt
JSON_RULE='Return ONLY valid JSON — no markdown fences, no explanation, no extra text. Every numeric field must be a number, not a string.'

if [ -n "$CUSTOM_PROMPT" ]; then
  # User-supplied prompt — used verbatim; user is responsible for the JSON schema
  PROMPT="$CUSTOM_PROMPT"
  echo "    Prompt:     <custom>"
else
  echo "    Prompt:     $PROMPT_PRESET"
  case "$PROMPT_PRESET" in

    standard)
      # Balanced sweep — good for PR gates and general CI checks
      PROMPT="You are a senior software engineer performing a production code review.
Analyze the provided source code strictly and objectively across these four dimensions:

1. Maintainability — naming clarity, method length, readability, inline documentation
2. Security — hardcoded secrets, injection risks, insecure patterns, OWASP Top 10
3. Performance — algorithmic efficiency, unnecessary iterations, blocking calls, memory waste
4. Reliability — error handling, null safety, resource cleanup, edge case coverage

$SCORING_GUIDE

Also count:
- code_smells: total number of code smell instances (duplication, magic numbers, long methods, dead code, etc.)
- critical_issues: number of issues that would cause bugs, outages, or security breaches in production
- overall_score: weighted average (security x2, reliability x2, maintainability x1, performance x1) / 6, rounded to 1 decimal
- summary: one concise sentence describing the dominant quality characteristic of this codebase

$JSON_RULE
Schema: {\"maintainability_score\":0-10,\"security_score\":0-10,\"performance_score\":0-10,\"reliability_score\":0-10,\"overall_score\":0-10,\"code_smells\":number,\"critical_issues\":number,\"summary\":\"string\"}"
      ;;

    security)
      # Deep OWASP/CVE focus — suitable as a security gate before deployment
      PROMPT="You are a senior application security engineer performing a SAST (Static Application Security Testing) review.
Analyze the provided source code exclusively for security vulnerabilities and risks.

Focus areas:
- OWASP Top 10: injection (SQL, command, LDAP, XPath), broken auth, sensitive data exposure,
  XML external entities, broken access control, security misconfiguration, XSS,
  insecure deserialization, known vulnerable components, insufficient logging
- Hardcoded credentials, API keys, tokens, or passwords in source code
- Insecure cryptography: weak algorithms (MD5, SHA1, DES), hardcoded IVs/salts, ECB mode
- Unvalidated input, missing output encoding, path traversal
- Insecure direct object references, missing authorization checks
- Race conditions, TOCTOU vulnerabilities
- Insecure third-party patterns or deprecated APIs with known CVEs

$SCORING_GUIDE
security_score applies to the overall security posture.
maintainability/performance/reliability: score these normally as secondary context.

severity field: assign the single highest risk level found across all issues.
  critical = exploitable vulnerability with high impact (RCE, auth bypass, data breach)
  high     = serious flaw likely exploitable under real conditions
  medium   = vulnerability requiring specific conditions or limited impact
  low      = minor security hygiene issues
  none     = no security issues found

vulnerabilities_count: total distinct vulnerability instances found.

$JSON_RULE
Schema: {\"security_score\":0-10,\"maintainability_score\":0-10,\"performance_score\":0-10,\"reliability_score\":0-10,\"overall_score\":0-10,\"code_smells\":number,\"critical_issues\":number,\"severity\":\"none|low|medium|high|critical\",\"vulnerabilities_count\":number,\"summary\":\"string\"}"
      ;;

    tech-debt)
      # Maintainability/refactoring focus — use for tracking codebase health over time
      PROMPT="You are a principal engineer performing a technical debt assessment.
Analyze the provided source code for maintainability issues, complexity, and accumulated technical debt.

Assess each of these dimensions:
1. Maintainability — naming conventions, method length, class cohesion, comments/docs quality
2. Duplication — copy-paste code, repeated logic, near-duplicate functions or classes
3. Complexity — deeply nested logic, high cyclomatic complexity indicators, god classes/methods
4. Performance — inefficient patterns, unnecessary work, poor algorithm choices
5. Security — surface-level check for obvious issues (not a deep security audit)
6. Reliability — error handling completeness, defensive coding practices

$SCORING_GUIDE

Also provide:
- code_smells: count of individual smell instances (magic numbers, long parameter lists,
  feature envy, inappropriate intimacy, data clumps, dead code, TODOs/FIXMEs, etc.)
- critical_issues: issues that would cause immediate bugs or failures
- debt_hours_estimate: rough hours a mid-level engineer would need to remediate all identified debt
  (be conservative — estimate only what is visible in the provided code)
- overall_score: average of all six dimension scores, rounded to 1 decimal
- summary: one sentence naming the top 1-2 debt drivers in this codebase

$JSON_RULE
Schema: {\"maintainability_score\":0-10,\"duplication_score\":0-10,\"complexity_score\":0-10,\"performance_score\":0-10,\"security_score\":0-10,\"reliability_score\":0-10,\"overall_score\":0-10,\"code_smells\":number,\"critical_issues\":number,\"debt_hours_estimate\":number,\"summary\":\"string\"}"
      ;;

    full-audit)
      # Complete report — all dimensions + specific findings + recommendations
      # Note: uses more tokens; consider using a larger model (e.g. gpt-4o, claude-opus-4-6)
      PROMPT="You are a principal software engineer performing a comprehensive code quality audit.
Analyze the provided source code across ALL of the following dimensions:

1. Maintainability — naming, readability, method/class length, cohesion, documentation
2. Security — OWASP Top 10, hardcoded secrets, injection, insecure crypto, auth issues
3. Performance — algorithmic complexity, memory usage, blocking calls, inefficient patterns
4. Reliability — error handling, null safety, resource cleanup, resilience, edge cases
5. Testability — coupling, side effects, dependency injection, pure functions, observability
6. Complexity — cyclomatic complexity signals, deep nesting, god classes, long call chains

$SCORING_GUIDE

Additionally provide:
- overall_score: weighted score (security x2, reliability x2, maintainability x1.5,
  performance x1, testability x1, complexity x0.5) normalised to 0-10, rounded to 1 decimal
- code_smells: total count of individual smell instances
- critical_issues: issues causing bugs, outages, or security breaches
- severity: highest risk level found (none | low | medium | high | critical)
- debt_hours_estimate: hours to remediate all visible debt (conservative estimate)
- findings_count: total number of distinct findings (all severities)
- top_finding: the single most important issue found — one sentence, specific (e.g. file/function if visible)
- top_recommendation: the single most impactful improvement action — one actionable sentence
- summary: two sentences max — overall health assessment and most critical next step

$JSON_RULE
Schema: {\"maintainability_score\":0-10,\"security_score\":0-10,\"performance_score\":0-10,\"reliability_score\":0-10,\"testability_score\":0-10,\"complexity_score\":0-10,\"overall_score\":0-10,\"code_smells\":number,\"critical_issues\":number,\"severity\":\"none|low|medium|high|critical\",\"debt_hours_estimate\":number,\"findings_count\":number,\"top_finding\":\"string\",\"top_recommendation\":\"string\",\"summary\":\"string\"}"
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# Auto-select model from provider's live models API
#
# When PLUGIN_MODEL is empty, query the provider for available models,
# filter to generation-capable ones, and pick the best fit for the preset.
# Falls back to hardcoded defaults if the API call fails.
# ---------------------------------------------------------------------------

# Return first match from a preference list that exists in available_models
pick_from_preference() {
  local available="$1"   # newline-separated list of model IDs
  shift
  for candidate in "$@"; do
    # exact match first
    if echo "$available" | grep -qx "$candidate"; then
      echo "$candidate"; return
    fi
    # prefix match (e.g. "claude-opus" matches "claude-opus-4-6")
    local match
    match=$(echo "$available" | grep "^${candidate}" | sort -rV | head -1)
    if [ -n "$match" ]; then
      echo "$match"; return
    fi
  done
  # last resort — first in the available list
  echo "$available" | head -1
}

select_model() {
  local provider="$1"
  local preset="$2"

  echo "==> Auto-selecting model (querying $provider models API)..."

  case "$provider" in

    openai)
      local raw
      raw=$(curl -sS --max-time 10 https://api.openai.com/v1/models \
        -H "Authorization: Bearer $API_KEY" 2>/dev/null) || true

      local available
      available=$(echo "$raw" \
        | jq -r '.data[].id' 2>/dev/null \
        | grep -E '^(gpt-4|gpt-3\.5|o1|o3|o4)' \
        | grep -vE '(instruct|realtime|audio|whisper|tts|dall-e|embedding|vision|0301|0314|0613)' \
        | sort -rV || true)

      if [ -z "$available" ]; then
        echo "    (models API unavailable — using hardcoded defaults)" >&2
        [ "$preset" = "full-audit" ] && echo "gpt-4o" || echo "gpt-4o-mini"
        return
      fi

      echo "    Available OpenAI models: $(echo "$available" | tr '\n' ' ')" >&2

      if [ "$preset" = "full-audit" ]; then
        pick_from_preference "$available" \
          "o3" "o1" "gpt-4.5" "gpt-4o" "gpt-4-turbo" "gpt-4" "gpt-4o-mini" "gpt-3.5-turbo"
      else
        # standard / security / tech-debt — prefer fast + cheap
        pick_from_preference "$available" \
          "gpt-4o-mini" "gpt-3.5-turbo" "gpt-4o" "gpt-4-turbo" "gpt-4"
      fi
      ;;

    anthropic)
      local raw
      raw=$(curl -sS --max-time 10 https://api.anthropic.com/v1/models \
        -H "x-api-key: $API_KEY" \
        -H "anthropic-version: 2023-06-01" 2>/dev/null) || true

      local available
      available=$(echo "$raw" \
        | jq -r '.data[].id' 2>/dev/null \
        | grep '^claude' \
        | sort -rV || true)

      if [ -z "$available" ]; then
        echo "    (models API unavailable — using hardcoded defaults)" >&2
        [ "$preset" = "full-audit" ] && echo "claude-opus-4-6" || echo "claude-sonnet-4-6"
        return
      fi

      echo "    Available Anthropic models: $(echo "$available" | tr '\n' ' ')" >&2

      if [ "$preset" = "full-audit" ]; then
        pick_from_preference "$available" \
          "claude-opus" "claude-sonnet" "claude-haiku"
      else
        pick_from_preference "$available" \
          "claude-haiku" "claude-sonnet" "claude-opus"
      fi
      ;;

    gemini)
      local raw
      raw=$(curl -sS --max-time 10 \
        "https://generativelanguage.googleapis.com/v1beta/models?key=${API_KEY}" \
        2>/dev/null) || true

      local available
      available=$(echo "$raw" \
        | jq -r '.models[] | select(.supportedGenerationMethods[] | contains("generateContent")) | .name' \
        2>/dev/null \
        | sed 's|^models/||' \
        | grep '^gemini' \
        | grep -vE '(embedding|vision|aqa)' \
        | sort -rV || true)

      if [ -z "$available" ]; then
        echo "    (models API unavailable — using hardcoded defaults)" >&2
        [ "$preset" = "full-audit" ] && echo "gemini-1.5-pro" || echo "gemini-1.5-flash"
        return
      fi

      echo "    Available Gemini models: $(echo "$available" | tr '\n' ' ')" >&2

      if [ "$preset" = "full-audit" ]; then
        pick_from_preference "$available" \
          "gemini-2.0-pro" "gemini-2.0" "gemini-1.5-pro" "gemini-pro" "gemini-1.5-flash" "gemini-flash"
      else
        pick_from_preference "$available" \
          "gemini-2.0-flash" "gemini-1.5-flash" "gemini-flash" "gemini-1.5-pro" "gemini-pro"
      fi
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Resolve model: auto-select if not specified
# ---------------------------------------------------------------------------
if [ -z "$MODEL" ]; then
  MODEL=$(select_model "$PROVIDER" "$PROMPT_PRESET")
  echo "    Auto-selected: $MODEL"
else
  echo "    Model (pinned): $MODEL"
fi

# ---------------------------------------------------------------------------
# Progress heartbeat — prints a "still waiting" line every 30 s so the
# Harness build log proves the step is alive during long LLM calls.
# ---------------------------------------------------------------------------
_HEARTBEAT_PID=""

start_heartbeat() {
  local label="$1"
  (
    local start
    start=$(date +%s)
    while true; do
      sleep 30
      local elapsed=$(( $(date +%s) - start ))
      local mins=$(( elapsed / 60 ))
      local secs=$(( elapsed % 60 ))
      printf "    ... waiting for %s response (%dm%02ds) — LLM is still processing ...\n" \
        "$label" "$mins" "$secs"
    done
  ) &
  _HEARTBEAT_PID=$!
}

stop_heartbeat() {
  if [ -n "$_HEARTBEAT_PID" ]; then
    kill "$_HEARTBEAT_PID" 2>/dev/null || true
    wait "$_HEARTBEAT_PID" 2>/dev/null || true
    _HEARTBEAT_PID=""
  fi
}

# ---------------------------------------------------------------------------
# Unified LLM caller with timeout, retry, and heartbeat
#
# Populates globals:  LLM_CONTENT   — extracted model text (on success)
#                     RAW_RESPONSE  — last raw API JSON (for error reporting)
# Returns 0 on success, 1 when all attempts are exhausted.
# ---------------------------------------------------------------------------
LLM_CONTENT=""
RAW_RESPONSE=""

call_llm() {
  local provider="$1"
  local max_attempts=$(( RETRY_COUNT + 1 ))
  local attempt=1
  local tmp
  tmp=$(mktemp)

  echo "    Model:      $MODEL"
  echo "    Timeout:    ${TIMEOUT_SECONDS}s per attempt  (max attempts: ${max_attempts})"

  while [ "$attempt" -le "$max_attempts" ]; do
    if [ "$attempt" -gt 1 ]; then
      local backoff=$(( (attempt - 1) * 15 ))
      echo ""
      echo "    --- Retry $((attempt - 1)) of $RETRY_COUNT — waiting ${backoff}s before retrying ---"
      sleep "$backoff"
    fi

    local curl_exit=0

    start_heartbeat "$provider"

    case "$provider" in

      openai)
        local payload
        payload=$(jq -n \
          --arg model "$MODEL" \
          --arg system "You are a strict code quality reviewer." \
          --arg user "$PROMPT

Code:
$CODE" \
          '{model:$model,messages:[{role:"system",content:$system},{role:"user",content:$user}]}')

        local response
        response=$(curl -sS --max-time "$TIMEOUT_SECONDS" \
          https://api.openai.com/v1/chat/completions \
          -H "Authorization: Bearer $API_KEY" \
          -H "Content-Type: application/json" \
          -d "$payload") || curl_exit=$?

        RAW_RESPONSE="$response"
        [ "$curl_exit" -eq 0 ] && \
          echo "$response" | jq -r '.choices[0].message.content // empty' > "$tmp"
        ;;

      anthropic)
        local payload
        payload=$(jq -n \
          --arg model "$MODEL" \
          --arg system "You are a strict code quality reviewer." \
          --arg user "$PROMPT

Code:
$CODE" \
          '{model:$model,max_tokens:4096,system:$system,messages:[{role:"user",content:$user}]}')

        local response
        response=$(curl -sS --max-time "$TIMEOUT_SECONDS" \
          https://api.anthropic.com/v1/messages \
          -H "x-api-key: $API_KEY" \
          -H "anthropic-version: 2023-06-01" \
          -H "Content-Type: application/json" \
          -d "$payload") || curl_exit=$?

        RAW_RESPONSE="$response"
        [ "$curl_exit" -eq 0 ] && \
          echo "$response" | jq -r '.content[0].text // empty' > "$tmp"
        ;;

      gemini)
        local payload
        payload=$(jq -n \
          --arg text "You are a strict code quality reviewer.

$PROMPT

Code:
$CODE" \
          '{contents:[{role:"user",parts:[{text:$text}]}]}')

        local response
        response=$(curl -sS --max-time "$TIMEOUT_SECONDS" \
          "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}" \
          -H "Content-Type: application/json" \
          -d "$payload") || curl_exit=$?

        RAW_RESPONSE="$response"
        [ "$curl_exit" -eq 0 ] && \
          echo "$response" | jq -r '.candidates[0].content.parts[0].text // empty' > "$tmp"
        ;;

    esac

    stop_heartbeat

    # ---- Diagnose curl exit code -------------------------------------------
    if [ "$curl_exit" -eq 28 ]; then
      echo ""
      echo "  TIMEOUT (attempt $attempt/$max_attempts): $provider did not respond"
      echo "          within ${TIMEOUT_SECONDS}s."
      echo "          Tip: increase PLUGIN_TIMEOUT_SECONDS (current: ${TIMEOUT_SECONDS})."
      attempt=$(( attempt + 1 ))
      continue
    elif [ "$curl_exit" -ne 0 ]; then
      echo ""
      echo "  NETWORK ERROR (attempt $attempt/$max_attempts): curl exited with code $curl_exit"
      echo "          while calling $provider. Check connectivity and API endpoint."
      attempt=$(( attempt + 1 ))
      continue
    fi

    # ---- Check for empty content -------------------------------------------
    LLM_CONTENT=$(cat "$tmp")
    if [ -z "$LLM_CONTENT" ]; then
      echo ""
      echo "  EMPTY RESPONSE (attempt $attempt/$max_attempts): $provider returned no text."
      echo "  Raw API response:"
      echo "$RAW_RESPONSE" | jq . 2>/dev/null || echo "$RAW_RESPONSE"
      attempt=$(( attempt + 1 ))
      continue
    fi

    rm -f "$tmp"
    return 0    # success
  done

  rm -f "$tmp"
  echo ""
  echo "ERROR: All $max_attempts attempt(s) to call $provider failed."
  echo "       Last raw API response:"
  echo "$RAW_RESPONSE" | jq . 2>/dev/null || echo "$RAW_RESPONSE"
  return 1
}

# ---------------------------------------------------------------------------
# Call the selected provider
# ---------------------------------------------------------------------------
echo ""
echo "==> Calling $PROVIDER API..."

if ! call_llm "$PROVIDER"; then
  exit 1
fi

MODEL_CONTENT="$LLM_CONTENT"

# ---------------------------------------------------------------------------
# Strip markdown fences if model wrapped JSON in ```json ... ```
# ---------------------------------------------------------------------------
RESULT_JSON=$(printf '%s\n' "$MODEL_CONTENT" \
  | sed \
    -e '1s/^[[:space:]]*```json[[:space:]]*//' \
    -e '1s/^[[:space:]]*```[[:space:]]*//' \
    -e '$s/[[:space:]]*```[[:space:]]*//')

if ! echo "$RESULT_JSON" | jq -e . >/dev/null 2>&1; then
  echo "ERROR: Model response is not valid JSON."
  echo "Raw model content:"
  printf '%s\n' "$MODEL_CONTENT"
  exit 1
fi

# ---------------------------------------------------------------------------
# Extract fields — all presets; fields absent in the current preset → "N/A"
# ---------------------------------------------------------------------------
MAINTAINABILITY_SCORE=$(echo "$RESULT_JSON" | jq -r '.maintainability_score // "N/A"')
SECURITY_SCORE=$(echo        "$RESULT_JSON" | jq -r '.security_score        // "N/A"')
PERFORMANCE_SCORE=$(echo     "$RESULT_JSON" | jq -r '.performance_score     // "N/A"')
RELIABILITY_SCORE=$(echo     "$RESULT_JSON" | jq -r '.reliability_score     // "N/A"')
TESTABILITY_SCORE=$(echo     "$RESULT_JSON" | jq -r '.testability_score     // "N/A"')
COMPLEXITY_SCORE=$(echo      "$RESULT_JSON" | jq -r '.complexity_score      // "N/A"')
DUPLICATION_SCORE=$(echo     "$RESULT_JSON" | jq -r '.duplication_score     // "N/A"')
OVERALL_SCORE=$(echo         "$RESULT_JSON" | jq -r '.overall_score         // "N/A"')
CODE_SMELLS=$(echo           "$RESULT_JSON" | jq -r '.code_smells           // "N/A"')
CRITICAL_ISSUES=$(echo       "$RESULT_JSON" | jq -r '.critical_issues       // "N/A"')
SEVERITY=$(echo              "$RESULT_JSON" | jq -r '.severity              // "N/A"')
DEBT_HOURS_ESTIMATE=$(echo   "$RESULT_JSON" | jq -r '.debt_hours_estimate   // "N/A"')
FINDINGS_COUNT=$(echo        "$RESULT_JSON" | jq -r '.findings_count        // "N/A"')
TOP_FINDING=$(echo           "$RESULT_JSON" | jq -r '.top_finding           // "N/A"')
TOP_RECOMMENDATION=$(echo    "$RESULT_JSON" | jq -r '.top_recommendation    // "N/A"')
SUMMARY=$(echo               "$RESULT_JSON" | jq -r '.summary // .overall_summary // "N/A"')

# ---------------------------------------------------------------------------
# Print report
# ---------------------------------------------------------------------------
echo ""
echo "========================================="
echo " AI Code Quality Report"
echo "========================================="
echo " Provider:            $PROVIDER"
echo " Preset:              $PROMPT_PRESET"
echo "-----------------------------------------"
[ "$OVERALL_SCORE"         != "N/A" ] && echo " Overall Score:       $OVERALL_SCORE / 10"
[ "$MAINTAINABILITY_SCORE" != "N/A" ] && echo " Maintainability:     $MAINTAINABILITY_SCORE / 10"
[ "$SECURITY_SCORE"        != "N/A" ] && echo " Security:            $SECURITY_SCORE / 10"
[ "$PERFORMANCE_SCORE"     != "N/A" ] && echo " Performance:         $PERFORMANCE_SCORE / 10"
[ "$RELIABILITY_SCORE"     != "N/A" ] && echo " Reliability:         $RELIABILITY_SCORE / 10"
[ "$TESTABILITY_SCORE"     != "N/A" ] && echo " Testability:         $TESTABILITY_SCORE / 10"
[ "$COMPLEXITY_SCORE"      != "N/A" ] && echo " Complexity:          $COMPLEXITY_SCORE / 10"
[ "$DUPLICATION_SCORE"     != "N/A" ] && echo " Duplication:         $DUPLICATION_SCORE / 10"
echo "-----------------------------------------"
[ "$SEVERITY"              != "N/A" ] && echo " Severity:            $SEVERITY"
[ "$CODE_SMELLS"           != "N/A" ] && echo " Code Smells:         $CODE_SMELLS"
[ "$CRITICAL_ISSUES"       != "N/A" ] && echo " Critical Issues:     $CRITICAL_ISSUES"
[ "$FINDINGS_COUNT"        != "N/A" ] && echo " Findings Count:      $FINDINGS_COUNT"
[ "$DEBT_HOURS_ESTIMATE"   != "N/A" ] && echo " Debt Estimate:       ~${DEBT_HOURS_ESTIMATE}h to remediate"
[ "$TOP_FINDING"           != "N/A" ] && echo " Top Finding:         $TOP_FINDING"
[ "$TOP_RECOMMENDATION"    != "N/A" ] && echo " Top Recommendation:  $TOP_RECOMMENDATION"
echo " Summary:             $SUMMARY"
echo "========================================="

# ---------------------------------------------------------------------------
# Write output variables for Harness
# Harness sets DRONE_OUTPUT to the path of the output file.
# ---------------------------------------------------------------------------
OUTPUT_FILE="${DRONE_OUTPUT:-/harness/output.env}"
mkdir -p "$(dirname "$OUTPUT_FILE")" 2>/dev/null || true

{
  echo "PROMPT_PRESET=$PROMPT_PRESET"
  echo "MAINTAINABILITY_SCORE=$MAINTAINABILITY_SCORE"
  echo "SECURITY_SCORE=$SECURITY_SCORE"
  echo "PERFORMANCE_SCORE=$PERFORMANCE_SCORE"
  echo "RELIABILITY_SCORE=$RELIABILITY_SCORE"
  echo "TESTABILITY_SCORE=$TESTABILITY_SCORE"
  echo "COMPLEXITY_SCORE=$COMPLEXITY_SCORE"
  echo "DUPLICATION_SCORE=$DUPLICATION_SCORE"
  echo "OVERALL_SCORE=$OVERALL_SCORE"
  echo "CODE_SMELLS=$CODE_SMELLS"
  echo "CRITICAL_ISSUES=$CRITICAL_ISSUES"
  echo "SEVERITY=$SEVERITY"
  echo "DEBT_HOURS_ESTIMATE=$DEBT_HOURS_ESTIMATE"
  echo "FINDINGS_COUNT=$FINDINGS_COUNT"
  echo "TOP_FINDING=$TOP_FINDING"
  echo "TOP_RECOMMENDATION=$TOP_RECOMMENDATION"
  echo "SUMMARY=$SUMMARY"
} > "$OUTPUT_FILE"

echo ""
echo "Output variables written to: $OUTPUT_FILE"

# ---------------------------------------------------------------------------
# Quality gate — evaluate all thresholds and fail if any are violated
# ---------------------------------------------------------------------------

# Returns 0 (true) if $1 is a usable numeric value (not N/A / empty)
is_numeric() {
  [ -z "$1" ] && return 1
  [ "$1" = "N/A" ] && return 1
  awk -v v="$1" 'BEGIN { exit !(v == v+0) }' 2>/dev/null
}

# Returns 0 (true) if float $1 is strictly below float $2
is_below() { awk -v val="$1" -v thr="$2" 'BEGIN { exit !(val < thr) }'; }

# Returns 0 (true) if integer $1 is strictly above integer $2
is_above() { awk -v val="$1" -v thr="$2" 'BEGIN { exit !(val > thr) }'; }

GATE_VIOLATIONS=()

# ── Blocking: critical issues ────────────────────────────────────────────────
if [ "$FAIL_ON_CRITICAL" = "true" ]; then
  if is_numeric "$CRITICAL_ISSUES" && is_above "$CRITICAL_ISSUES" "0"; then
    GATE_VIOLATIONS+=("Critical issues: ${CRITICAL_ISSUES} found (threshold: 0)")
  fi
fi

# ── Blocking: severity ───────────────────────────────────────────────────────
if [ "$FAIL_ON_SEVERITY" != "none" ] && [ "$SEVERITY" != "N/A" ] && [ "$SEVERITY" != "none" ] && [ -n "$SEVERITY" ]; then
  sev_fail=false
  case "$FAIL_ON_SEVERITY" in
    medium)
      if [ "$SEVERITY" = "medium" ] || [ "$SEVERITY" = "high" ] || [ "$SEVERITY" = "critical" ]; then
        sev_fail=true
      fi
      ;;
    high)
      if [ "$SEVERITY" = "high" ] || [ "$SEVERITY" = "critical" ]; then
        sev_fail=true
      fi
      ;;
    critical)
      if [ "$SEVERITY" = "critical" ]; then
        sev_fail=true
      fi
      ;;
  esac
  if [ "$sev_fail" = "true" ]; then
    GATE_VIOLATIONS+=("Severity: '${SEVERITY}' meets or exceeds block level '${FAIL_ON_SEVERITY}'")
  fi
fi

# ── Score minimums (skip if threshold is 0 or score is N/A) ─────────────────
check_score() {
  local label="$1" value="$2" threshold="$3"
  [ "$threshold" = "0" ] && return 0
  is_numeric "$value" || return 0
  is_numeric "$threshold" || return 0
  if is_below "$value" "$threshold"; then
    GATE_VIOLATIONS+=("${label}: ${value}/10 is below minimum (${threshold})")
  fi
}

check_score "Overall score"         "$OVERALL_SCORE"         "$MIN_OVERALL_SCORE"
check_score "Security score"        "$SECURITY_SCORE"        "$MIN_SECURITY_SCORE"
check_score "Reliability score"     "$RELIABILITY_SCORE"     "$MIN_RELIABILITY_SCORE"
check_score "Maintainability score" "$MAINTAINABILITY_SCORE" "$MIN_MAINTAINABILITY_SCORE"
check_score "Performance score"     "$PERFORMANCE_SCORE"     "$MIN_PERFORMANCE_SCORE"
check_score "Testability score"     "$TESTABILITY_SCORE"     "$MIN_TESTABILITY_SCORE"
check_score "Complexity score"      "$COMPLEXITY_SCORE"      "$MIN_COMPLEXITY_SCORE"
check_score "Duplication score"     "$DUPLICATION_SCORE"     "$MIN_DUPLICATION_SCORE"

# ── Count maximums (skip if threshold is -1 or value is N/A) ────────────────
check_count() {
  local label="$1" value="$2" threshold="$3"
  [ "$threshold" = "-1" ] && return 0
  is_numeric "$value"     || return 0
  is_numeric "$threshold" || return 0
  if is_above "$value" "$threshold"; then
    GATE_VIOLATIONS+=("${label}: ${value} exceeds maximum (${threshold})")
  fi
}

check_count "Code smells"      "$CODE_SMELLS"       "$MAX_CODE_SMELLS"
check_count "Debt hours"       "$DEBT_HOURS_ESTIMATE" "$MAX_DEBT_HOURS"
check_count "Findings count"   "$FINDINGS_COUNT"    "$MAX_FINDINGS_COUNT"

# ── Print result ─────────────────────────────────────────────────────────────
echo ""
if [ "${#GATE_VIOLATIONS[@]}" -gt 0 ]; then
  echo "========================================="
  echo " QUALITY GATE: FAILED"
  echo "========================================="
  for violation in "${GATE_VIOLATIONS[@]}"; do
    echo "  FAIL  $violation"
  done
  echo "-----------------------------------------"
  [ "$TOP_FINDING"        != "N/A" ] && echo " Top Finding:         $TOP_FINDING"
  [ "$TOP_RECOMMENDATION" != "N/A" ] && echo " Top Recommendation:  $TOP_RECOMMENDATION"
  echo " Summary:             $SUMMARY"
  echo "========================================="
  echo ""
  echo "To adjust thresholds, set these plugin settings:"
  echo "  fail_on_critical: true|false"
  echo "  fail_on_severity: critical|high|medium|none"
  echo "  min_overall_score / min_security_score / min_reliability_score"
  echo "  min_maintainability_score / min_performance_score"
  echo "  min_testability_score / min_complexity_score / min_duplication_score"
  echo "  max_code_smells / max_debt_hours / max_findings_count"
  exit 1
else
  echo "========================================="
  echo " QUALITY GATE: PASSED"
  echo "========================================="
  echo " All configured thresholds met."
  echo "========================================="
fi

exit 0
