# AI Code Quality Scanner — Harness Plugin

A Harness CI plugin that scans your source code using large language models and enforces configurable quality gates. Supports **OpenAI**, **Anthropic**, and **Google Gemini** as providers.

Docker image: `anandraiin3/harness-code-quality:latest`

---

## What it does

The plugin collects source files from your workspace, sends them to an LLM for analysis, and produces structured quality scores and findings as pipeline output variables. It then evaluates those results against configurable thresholds and fails the step (blocking the build) if any threshold is breached.

**Analysis dimensions:**

| Dimension | Description |
|---|---|
| Overall Score | Weighted aggregate across all dimensions (0–10) |
| Maintainability | Naming clarity, method length, readability, documentation |
| Security | OWASP Top 10, hardcoded secrets, injection risks, insecure patterns |
| Performance | Algorithmic efficiency, blocking calls, memory waste |
| Reliability | Error handling, null safety, resource cleanup, edge cases |
| Testability | Coupling, side effects, dependency injection *(full-audit only)* |
| Complexity | Cyclomatic complexity, nesting depth, god classes *(full-audit + tech-debt)* |
| Duplication | Copy-paste code, near-duplicate logic *(full-audit + tech-debt)* |

**Counts and findings:**

- `CRITICAL_ISSUES` — issues that would cause bugs, outages, or security breaches
- `CODE_SMELLS` — total smell instances (magic numbers, dead code, long methods, etc.)
- `SEVERITY` — highest risk level found: `none` / `low` / `medium` / `high` / `critical`
- `FINDINGS_COUNT` — total distinct findings across all severities
- `DEBT_HOURS_ESTIMATE` — estimated hours to remediate visible technical debt
- `TOP_FINDING` — single most important issue, one sentence
- `TOP_RECOMMENDATION` — most impactful improvement action, one sentence
- `SUMMARY` — one-to-two sentence overall assessment

---

## Analysis profiles

Select the depth and focus of the scan using `prompt_preset`:

| Profile | When to use | Extra outputs |
|---|---|---|
| `standard` | Every build — balanced sweep across all four core dimensions | — |
| `security` | Pre-deployment gate — deep OWASP/CVE focus | `severity`, `vulnerabilities_count` |
| `tech-debt` | Quarterly review — maintainability and debt tracking | `duplication_score`, `complexity_score`, `debt_hours_estimate` |
| `full-audit` | PR-to-main gate — complete report, all dimensions | All outputs including `testability_score`, `top_finding`, `top_recommendation` |

You can also supply a `custom_prompt` to override the preset entirely with your own analysis instructions (e.g. PCI-DSS compliance check). Your custom prompt must instruct the LLM to return JSON.

> **Warning:** The output variable names are fixed and must match exactly — changing the JSON field names in your custom prompt will break the plugin's output variable mapping. Your custom prompt must return a JSON object using the field names listed below. Any field not present in the response will be set to `N/A` in the pipeline variables.
>
> Required JSON schema for custom prompts:
> ```json
> {
>   "overall_score": 0-10,
>   "maintainability_score": 0-10,
>   "security_score": 0-10,
>   "performance_score": 0-10,
>   "reliability_score": 0-10,
>   "testability_score": 0-10,
>   "complexity_score": 0-10,
>   "duplication_score": 0-10,
>   "code_smells": number,
>   "critical_issues": number,
>   "severity": "none|low|medium|high|critical",
>   "debt_hours_estimate": number,
>   "findings_count": number,
>   "top_finding": "string",
>   "top_recommendation": "string",
>   "summary": "string"
> }
> ```
> Include only the fields relevant to your analysis. Fields omitted from the response are skipped by the quality gate — they will not cause failures.

---

## Quality gate

The step evaluates results against thresholds and exits with a non-zero code if any are violated, failing the Harness step and blocking downstream execution.

**Default thresholds:**

| Check | Default | Behaviour |
|---|---|---|
| `fail_on_critical` | `true` (full-audit) / `false` (standard) | Blocks if `CRITICAL_ISSUES > 0` |
| `fail_on_severity` | `high` | Blocks if severity is `high` or `critical` |
| `min_overall_score` | `6` | Blocks if overall score < 6 |
| `min_security_score` | `7` | Blocks if security score < 7 |
| `min_reliability_score` | `7` | Blocks if reliability score < 7 |
| `min_maintainability_score` | `6` | Blocks if maintainability score < 6 |
| `min_performance_score` | `6` | Blocks if performance score < 6 |
| `min_testability_score` | `5` | Blocks if testability score < 5 (skipped if N/A) |
| `min_complexity_score` | `5` | Blocks if complexity score < 5 (skipped if N/A) |
| `min_duplication_score` | `6` | Blocks if duplication score < 6 (skipped if N/A) |
| `max_code_smells` | `-1` (disabled) | Blocks if count exceeds threshold |
| `max_debt_hours` | `-1` (disabled) | Blocks if debt hours exceed threshold |
| `max_findings_count` | `-1` (disabled) | Blocks if findings count exceeds threshold |

Set any score minimum to `0` or any count maximum to `-1` to disable that specific check.

---

## When to use it

| Trigger | Recommended profile | Gate strictness |
|---|---|---|
| Every commit / every build | `standard` | Lenient — warn on high/critical severity only |
| Pull request to `main` | `full-audit` | Strict — block on critical issues + all score thresholds |
| Pre-deployment (CD gate) | `security` | Medium — block on high/critical severity findings |
| Quarterly debt review | `tech-debt` | Informational — use output variables for trending dashboards |

---

## Prerequisites

1. **API key** — obtain a key from your chosen provider and store it as a Harness secret:
   - OpenAI: [platform.openai.com/api-keys](https://platform.openai.com/api-keys) → recommended secret name: `org.OPENAI_API_KEY`
   - Anthropic: [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) → recommended secret name: `org.ANTHROPIC_API_KEY`
   - Gemini: [aistudio.google.com/app/apikey](https://aistudio.google.com/app/apikey) → recommended secret name: `org.GEMINI_API_KEY`

2. **Docker connector** — a Harness Docker Hub connector to pull the plugin image (e.g. `account.Dockerhub`).

---

## Using the StepGroup template (recommended)

The repository includes a ready-made Harness StepGroup template (`pipeline-plugin-step.yaml`) with two steps pre-configured:

- **AI Code Quality Check** (`standard` preset) — runs on every build that is NOT a PR to `main`
- **AI Code Quality Full Audit** (`full-audit` preset) — runs only on PRs targeting `main`

Import the template at Organisation level in Harness, then add it to your CI stage:

```yaml
- stepGroup:
    name: Check_Code_Quality_Using_AI
    identifier: Check_Code_Quality_Using_AI
    template:
      templateRef: org.Check_Code_Quality_Using_AI
      versionLabel: v4
      templateInputs:
        steps:
          - step:
              identifier: AI_Code_Quality_Check
              type: Plugin
              spec:
                settings:
                  llm_provider: anthropic
                  api_key: <+secrets.getValue("org.ANTHROPIC_API_KEY")>
                  model: ""
                  scan_paths: src/
                  file_extensions: cs,py,js,ts
                  max_files: "20"
                  timeout_seconds: "300"
          - step:
              identifier: AI_Code_Quality_Full_Audit
              type: Plugin
              spec:
                settings:
                  llm_provider: anthropic
                  api_key: <+secrets.getValue("org.ANTHROPIC_API_KEY")>
                  model: ""
                  scan_paths: src/
                  file_extensions: cs,py,js,ts
                  max_files: "30"
                  timeout_seconds: "600"
```

---

## Using the plugin step directly

Add a Plugin step to your CI stage and reference the Docker image:

```yaml
- step:
    type: Plugin
    name: AI Code Quality Scan
    identifier: AI_Code_Quality_Scan
    spec:
      connectorRef: account.Dockerhub
      image: anandraiin3/harness-code-quality:latest
      settings:
        llm_provider: openai
        api_key: <+secrets.getValue("org.OPENAI_API_KEY")>
        model: ""                      # leave empty for auto-selection
        prompt_preset: standard
        scan_paths: src/api,src/models
        file_extensions: py,js,ts
        max_files: "20"
        timeout_seconds: "300"
        fail_on_critical: "false"
        fail_on_severity: high
        min_overall_score: "6"
        min_security_score: "7"
        min_reliability_score: "7"
        min_maintainability_score: "6"
        min_performance_score: "6"
      outputVariables:
        - name: OVERALL_SCORE
        - name: SECURITY_SCORE
        - name: SEVERITY
        - name: CRITICAL_ISSUES
        - name: SUMMARY
```

---

## Output variables

All output variables are pipeline-scoped and available in downstream steps via:

```
<+pipeline.stages.<stage_id>.spec.execution.steps.<step_id>.output.outputVariables.OVERALL_SCORE>
```

| Variable | Description | Presets |
|---|---|---|
| `OVERALL_SCORE` | Weighted overall quality score (0–10) | all |
| `MAINTAINABILITY_SCORE` | Naming, readability, method length, documentation (0–10) | all |
| `SECURITY_SCORE` | OWASP coverage, hardcoded secrets, insecure patterns (0–10) | all |
| `PERFORMANCE_SCORE` | Algorithmic efficiency, blocking calls, memory (0–10) | all |
| `RELIABILITY_SCORE` | Error handling, null safety, edge cases (0–10) | all |
| `CODE_SMELLS` | Total count of code smell instances | all |
| `CRITICAL_ISSUES` | Issues that would cause bugs, outages, or breaches | all |
| `SEVERITY` | Highest risk level: `none` / `low` / `medium` / `high` / `critical` | all |
| `SUMMARY` | One-to-two sentence overall assessment | all |
| `TESTABILITY_SCORE` | Coupling, side effects, dependency injection (0–10) | full-audit |
| `COMPLEXITY_SCORE` | Cyclomatic complexity, nesting, god classes (0–10) | full-audit, tech-debt |
| `DUPLICATION_SCORE` | Code duplication level (0–10) | full-audit, tech-debt |
| `DEBT_HOURS_ESTIMATE` | Hours to remediate all visible debt | full-audit, tech-debt |
| `FINDINGS_COUNT` | Total distinct findings across all severities | full-audit |
| `TOP_FINDING` | Single most important issue, one sentence | full-audit |
| `TOP_RECOMMENDATION` | Most impactful improvement action, one sentence | full-audit |
| `PROMPT_PRESET` | Which analysis profile ran | all |

---

## Model selection

Leave `model` empty to enable auto-selection. The plugin queries the provider's models API and picks the best fit for the selected preset:

- `standard` / `security` / `tech-debt` → lightweight, fast model (lower cost per build)
- `full-audit` → most capable available model (thorough analysis)

To pin a specific model, set its exact ID:

```
OpenAI:    gpt-4o  |  gpt-4o-mini  |  gpt-4-turbo
Anthropic: claude-opus-4-6  |  claude-sonnet-4-6  |  claude-haiku-4-5-20251001
Gemini:    gemini-1.5-pro  |  gemini-1.5-flash  |  gemini-2.0-flash
```

---

## OPA Policy-as-Code integration

The repository includes `codequalitypolicy.rego` — a Harness OPA policy that evaluates the plugin's output variables and produces structured `deny` (blocking) and `warn` (advisory) outcomes.

Import this policy at Organisation level and attach it to a Harness Policy step that receives the output variables as its payload. This allows the quality gate to be enforced centrally as an organisational policy rather than per-pipeline step settings.

Default thresholds in the policy align with:
- **SonarQube** Quality Gate grades
- **OWASP ASVS** L1/L2
- **PCI-DSS** Requirement 6
- **NIST 800-53** (no high/critical vulnerabilities in production code)

---

## All plugin settings reference

| Setting | Required | Default | Description |
|---|---|---|---|
| `llm_provider` | Yes | `openai` | `openai` / `anthropic` / `gemini` |
| `api_key` | Yes | — | Provider API key (use a Harness secret) |
| `model` | No | auto | Exact model ID, or empty for auto-selection |
| `prompt_preset` | No | `standard` | `standard` / `security` / `tech-debt` / `full-audit` |
| `custom_prompt` | No | — | Override preset with your own prompt (must instruct LLM to return JSON) |
| `scan_paths` | No | entire workspace | Comma-separated files or folders relative to workspace root |
| `file_extensions` | No | `cs,py,js,ts,java` | Comma-separated extensions to include |
| `max_files` | No | `20` | Max source files to send to the LLM |
| `max_chars` | No | `100000` | Max characters of source code to send |
| `timeout_seconds` | No | `300` | Max seconds per LLM API call |
| `retry_count` | No | `2` | Additional retry attempts on timeout/network error |
| `fail_on_critical` | No | `true` | Block if `CRITICAL_ISSUES > 0` |
| `fail_on_severity` | No | `high` | Block at this severity level or above (`critical` / `high` / `medium` / `none`) |
| `min_overall_score` | No | `6` | Minimum overall score (0 to disable) |
| `min_security_score` | No | `7` | Minimum security score (0 to disable) |
| `min_reliability_score` | No | `7` | Minimum reliability score (0 to disable) |
| `min_maintainability_score` | No | `6` | Minimum maintainability score (0 to disable) |
| `min_performance_score` | No | `6` | Minimum performance score (0 to disable) |
| `min_testability_score` | No | `5` | Minimum testability score (0 to disable, skipped if N/A) |
| `min_complexity_score` | No | `5` | Minimum complexity score (0 to disable, skipped if N/A) |
| `min_duplication_score` | No | `6` | Minimum duplication score (0 to disable, skipped if N/A) |
| `max_code_smells` | No | `-1` | Maximum code smells count (-1 to disable) |
| `max_debt_hours` | No | `-1` | Maximum debt hours (-1 to disable) |
| `max_findings_count` | No | `-1` | Maximum findings count (-1 to disable) |
