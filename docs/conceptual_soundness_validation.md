# Section 24 â€” Conceptual Soundness Validation Methodology

## Objective

Section 24 performs an independent conceptual-soundness challenge of the FICC Treasury
clearing liquidity stress-testing framework. The review evaluates whether the model's
economic logic, cash-flow construction, stress assumptions, resource treatment, and
synthetic-member calibration are coherent, conservative, reproducible, and supported by
controlled evidence.

The validation is intentionally independent from model development. A successful model run
does not establish conceptual soundness. The validator therefore combines:

1. Repository evidence inspection.
2. Required terminology and control coverage.
3. Deterministic quantitative sanity checks.
4. Weighted challenge scoring.
5. Critical-challenge escalation.
6. A controlled finding and remediation register.

## Scope

The following eleven domains are challenged:

1. Liquidity horizon.
2. Cash-flow definitions.
3. Default-set construction.
4. Yield-to-price methodology.
5. Repo rollover assumptions.
6. Haircut assumptions.
7. Settlement-fail treatment.
8. Resource eligibility.
9. Netting assumptions.
10. Scenario severity.
11. Synthetic-member calibration.

## Assessment logic

Each challenge receives:

- A challenge weight.
- A critical/noncritical designation.
- Controlled evidence-path patterns.
- Required evidence keyword groups.
- Independent quantitative checks.
- Explicit challenge questions.
- A risk statement.
- A required remediation statement.
- Regulatory and industry-standard mappings.

The challenge score is:

```text
50% evidence-keyword coverage
20% minimum controlled-file coverage
30% deterministic quantitative-check coverage
```

The status rules are:

```text
PASS:
    All required evidence groups are present.
    Minimum file coverage is met.
    All quantitative challenge checks pass.

PARTIAL:
    All quantitative checks pass.
    Evidence meets the partial threshold but one or more evidence groups or files are missing.

FAIL:
    A quantitative challenge fails, or evidence coverage is below the configured partial threshold.
```

Overall conclusions are:

```text
PASS:
    Every challenge passes and the weighted score meets the configured threshold.

ACCEPTABLE_WITH_FINDINGS:
    No critical challenge fails, but one or more partial/noncritical findings remain.

FAIL:
    One or more critical challenges fail.
```

A `FAIL` conclusion is a model-validation result, not a software execution error. The runner
still writes the complete evidence package so the finding can be remediated and retested.

## Challenge interpretation

### Liquidity horizon

The review determines whether the model captures intraday peaks, end-of-day settlement,
overnight requirements, and persistent multi-day stress. Resources must be available in the
same time bucket as the obligation they offset.

### Cash-flow definitions

The review challenges sign conventions, units, timing, conditionality, and integration of
settlement cash, repo principal, funding cost, haircut calls, Treasury liquidation losses,
settlement fails, concentration adjustments, and the operational buffer. Component identifiers
must prevent double counting.

### Default-set construction

Cover 1 must identify the single member generating the largest scenario-specific requirement.
Cover 2 must identify two distinct members. Concentrated and correlated default sets must remain
configurable and reproducible.

### Yield-to-price methodology

The model must apply basis-point conversion, modified duration, convexity, curve-shape shocks,
key-rate mappings, liquidation horizons, and market-impact assumptions consistently. Positive
yield shocks should reduce the value of a conventional long Treasury position.

### Repo rollover assumptions

Rollover-failure, lender-withdrawal, refinancing-horizon, funding-concentration, SOFR, and
additional collateral assumptions must be bounded, monotonic where expected, and separately
identified to prevent duplicate requirements.

### Haircut assumptions

Haircuts must be nonnegative, bounded, maturity-sensitive, stress-sensitive, and constrained by
available unencumbered collateral. Concentration adjustments must be applied once and in a
documented sequence.

### Settlement-fail treatment

Fails to receive, fails to deliver, delayed incoming payments, replacement liquidity, recoveries,
and persistent multi-day fails must be distinguished. Persistent fails must roll forward without
duplicating the original settlement obligation.

### Resource eligibility

Only qualifying liquid resources that are legally, operationally, and temporally available may
reduce the stressed requirement. Encumbered, ineligible, unavailable, or uncommitted resources
must be excluded or conservatively adjusted.

### Netting assumptions

Netting is permitted only for obligations within enforceable and operationally compatible
netting sets. Currency, settlement date, product, settlement system, and default-state
enforceability must be controlled. The model must revert to gross obligations when criteria fail.

### Scenario severity

Moderate, severe, and extreme-but-plausible scenarios must be coherent and sufficiently
differentiated. Combined scenarios should reflect plausible dependence rather than mechanically
adding every maximum. Reverse stress testing must identify threshold shocks that create an LCR
breach or liquidity shortfall.

### Synthetic-member calibration

Synthetic members must reconcile exactly to controlled Federal Reserve aggregates, remain
nonnegative, reproduce under deterministic seeds, preserve maturity/financing/fails totals, and
display explicitly controlled concentration and heavy-tail behavior. No member may be represented
as or inferred to be an actual FICC participant.

## Controlled outputs

The runner creates:

```text
reports/tables/section24_conceptual_soundness_matrix.csv
reports/tables/section24_conceptual_soundness_findings.csv
reports/evidence/section24_conceptual_soundness_summary.json
reports/evidence/section24_conceptual_soundness_validation.txt
reports/independent_validation/section24_conceptual_soundness_report.md
```

## Execution

From the repository root:

```powershell
.\.venv\Scripts\python.exe scripts\run_conceptual_soundness_validation.py `
  --project-root . `
  --config configs\conceptual_soundness_validation.yaml
```

## Standards basis

The challenge matrix is mapped to the CPMI-IOSCO Principles for Financial Market
Infrastructures, the PFMI assessment methodology, the CPMI-IOSCO CCP resilience guidance,
SEC Rule 17Ad-22 Covered Clearing Agency Standards, the FICC Disclosure Framework, and the
DTCC stress-testing framework.

These mappings define the assessment lens. They do not imply that this public-data project
reproduces FICC's confidential production models, member data, internal liquidity arrangements,
or proprietary scenario calibration.