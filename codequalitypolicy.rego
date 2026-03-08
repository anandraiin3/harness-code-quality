package security

############################
# CONFIGURABLE THRESHOLDS  #
#                          #
# Industry references:     #
#  - SonarQube Quality Gate#
#  - OWASP Top 10 / ASVS   #
#  - PCI-DSS / SOC 2       #
#  - ISO/IEC 25010         #
############################

# ── BLOCKING ──────────────────────────────────────────────────────────────────
# Zero tolerance for critical issues: enforced by OWASP, PCI-DSS, SOC 2, and
# most enterprise security policies. Any critical issue MUST be fixed before
# merge to main / deployment to production.
critical_issues_block_threshold := 0

# Block on critical and high severity findings.
# OWASP ASVS L2/L3 and NIST 800-53 require no high/critical vulnerabilities
# in production-facing code.
severity_block_values := {"critical", "high"}

# ── SCORE WARNINGS (warn if score BELOW threshold) ────────────────────────────
# Scores use our rubric: 8-10 = good, 5-7 = acceptable, 2-4 = significant problems.
# Thresholds are set at the bottom of the "acceptable" band or higher where
# the dimension directly affects production safety.

# Overall weighted score — SonarQube equivalent of "C" grade or below triggers gate.
overall_warn_threshold         := 6

# Security — higher bar aligned with OWASP ASVS L1 and PCI-DSS requirement 6.
# Score below 7 indicates issues that should be reviewed before deployment.
security_warn_threshold        := 7

# Reliability — impacts uptime and error rates. Higher bar aligned with
# SRE / SLA practices (5-nines targets require solid reliability posture).
reliability_warn_threshold     := 7

# Maintainability — SonarQube "B" grade equivalent. Below 6 indicates
# significant naming, readability, or documentation debt.
maintainability_warn_threshold := 6

# Performance — acceptable floor. Below 6 indicates inefficiencies that
# will compound at scale (aligned with Google SRE load-testing standards).
performance_warn_threshold     := 6

# Duplication — SonarQube flags > 3% duplication as "B" grade.
# Score below 6 in our rubric correlates with noticeable copy-paste debt.
duplication_warn_threshold     := 6

# Testability — more lenient; improving testability is a longer-term initiative.
# Below 5 indicates code is actively hostile to testing (tight coupling, globals).
testability_warn_threshold     := 5

# Complexity — below 5 signals god classes / deeply nested logic that pose
# a maintenance and bug-introduction risk.
complexity_warn_threshold      := 5

# ── COUNT WARNINGS (warn if count ABOVE threshold) ────────────────────────────

# Code smells — SonarQube new-code gate targets 0 new smells.
# For existing code scans, > 10 across the scanned files warrants attention.
code_smells_warn_threshold     := 10

# Total distinct findings — correlates with overall code health.
# > 10 findings in a single scan indicates a codebase needing active remediation.
findings_count_warn_threshold  := 10

# Technical debt estimate — 16 hours ≈ 2 working days.
# SonarQube's default debt ratio threshold is 5% of dev time;
# 16 hours is a practical "schedule a remediation sprint" signal.
debt_hours_warn_threshold      := 16

############################
# SAFE NUMBER CONVERSION   #
# Returns -1 (skip signal) #
# for N/A, null, empty, or #
# missing fields.           #
############################

# A value is "not applicable" if it is missing, empty, "N/A", or the string "null"
is_na(x) {
    not x
}
is_na(x) {
    x == ""
}
is_na(x) {
    x == "N/A"
}
is_na(x) {
    x == "null"
}

to_number_or_na(x) = n {
    not is_na(x)
    n := to_number(x)
} else = -1

# Safe string: returns the value if present and meaningful, otherwise ""
safe_str(x) = s {
    not is_na(x)
    s := x
} else = ""

############################
# NORMALIZED VALUES        #
# Harness resolves the     #
# ternary expressions in   #
# the Policy step payload  #
# before OPA evaluates, so #
# each field has exactly   #
# one clean value here.    #
############################

critical_issues    := to_number_or_na(input.CRITICAL_ISSUES)
code_smells        := to_number_or_na(input.CODE_SMELLS)
findings_count     := to_number_or_na(input.FINDINGS_COUNT)
debt_hours         := to_number_or_na(input.DEBT_HOURS_ESTIMATE)
overall            := to_number_or_na(input.OVERALL_SCORE)
maintainability    := to_number_or_na(input.MAINTAINABILITY_SCORE)
security           := to_number_or_na(input.SECURITY_SCORE)
performance        := to_number_or_na(input.PERFORMANCE_SCORE)
reliability        := to_number_or_na(input.RELIABILITY_SCORE)
testability        := to_number_or_na(input.TESTABILITY_SCORE)
complexity         := to_number_or_na(input.COMPLEXITY_SCORE)
duplication        := to_number_or_na(input.DUPLICATION_SCORE)

severity           := s { s := safe_str(input.SEVERITY);           s != "" } else = "none"
prompt_preset      := s { s := safe_str(input.PROMPT_PRESET);      s != "" } else = "unknown"
top_finding        := safe_str(input.TOP_FINDING)
top_recommendation := safe_str(input.TOP_RECOMMENDATION)
summary            := safe_str(input.SUMMARY)

############################
# BLOCKING CONDITIONS      #
############################

deny[msg] {
    critical_issues >= 0   # skip if N/A
    critical_issues > critical_issues_block_threshold

    msg := sprintf(
        "BLOCKED: %d critical issue(s) detected (threshold: %d).\nTop Finding: %s\nTop Recommendation: %s\nSummary: %s",
        [critical_issues, critical_issues_block_threshold, top_finding, top_recommendation, summary]
    )
}

deny[msg] {
    severity_block_values[severity]

    msg := sprintf(
        "BLOCKED: Severity level '%s' exceeds acceptable risk.\nTop Finding: %s\nTop Recommendation: %s\nSummary: %s",
        [severity, top_finding, top_recommendation, summary]
    )
}

############################
# SCORE WARNINGS           #
############################

warn[msg] {
    overall >= 0
    overall < overall_warn_threshold

    msg := sprintf(
        "Overall score is low: %.1f / 10 (threshold: %d) | Preset: %s\nSummary: %s",
        [overall, overall_warn_threshold, prompt_preset, summary]
    )
}

warn[msg] {
    maintainability >= 0
    maintainability < maintainability_warn_threshold

    msg := sprintf(
        "Maintainability score is low: %.1f / 10 (threshold: %d)\nTop Recommendation: %s",
        [maintainability, maintainability_warn_threshold, top_recommendation]
    )
}

warn[msg] {
    security >= 0
    security < security_warn_threshold

    msg := sprintf(
        "Security score is low: %.1f / 10 (threshold: %d)\nTop Finding: %s\nTop Recommendation: %s",
        [security, security_warn_threshold, top_finding, top_recommendation]
    )
}

warn[msg] {
    performance >= 0
    performance < performance_warn_threshold

    msg := sprintf(
        "Performance score is low: %.1f / 10 (threshold: %d)\nTop Recommendation: %s",
        [performance, performance_warn_threshold, top_recommendation]
    )
}

warn[msg] {
    reliability >= 0
    reliability < reliability_warn_threshold

    msg := sprintf(
        "Reliability score is low: %.1f / 10 (threshold: %d)\nTop Recommendation: %s",
        [reliability, reliability_warn_threshold, top_recommendation]
    )
}

warn[msg] {
    testability >= 0
    testability < testability_warn_threshold

    msg := sprintf(
        "Testability score is low: %.1f / 10 (threshold: %d)\nTop Recommendation: %s",
        [testability, testability_warn_threshold, top_recommendation]
    )
}

warn[msg] {
    complexity >= 0
    complexity < complexity_warn_threshold

    msg := sprintf(
        "Complexity score is low: %.1f / 10 (threshold: %d)\nTop Finding: %s",
        [complexity, complexity_warn_threshold, top_finding]
    )
}

warn[msg] {
    duplication >= 0
    duplication < duplication_warn_threshold

    msg := sprintf(
        "Duplication score is low: %.1f / 10 (threshold: %d)\nTop Recommendation: %s",
        [duplication, duplication_warn_threshold, top_recommendation]
    )
}

############################
# COUNT WARNINGS           #
############################

warn[msg] {
    code_smells >= 0
    code_smells > code_smells_warn_threshold

    msg := sprintf(
        "Code smells count is high: %d (threshold: %d)\nSummary: %s",
        [code_smells, code_smells_warn_threshold, summary]
    )
}

warn[msg] {
    findings_count >= 0
    findings_count > findings_count_warn_threshold

    msg := sprintf(
        "Total findings count is high: %d (threshold: %d)\nTop Finding: %s",
        [findings_count, findings_count_warn_threshold, top_finding]
    )
}

warn[msg] {
    debt_hours >= 0
    debt_hours > debt_hours_warn_threshold

    msg := sprintf(
        "Estimated technical debt is high: %d hours (threshold: %d hours)\nTop Recommendation: %s",
        [debt_hours, debt_hours_warn_threshold, top_recommendation]
    )
}

warn[msg] {
    severity == "medium"

    msg := sprintf(
        "Severity level '%s' detected — review before release.\nTop Finding: %s\nTop Recommendation: %s",
        [severity, top_finding, top_recommendation]
    )
}
