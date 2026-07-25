# Section 30 — Monitoring Thresholds and Escalation

## Objective

Section 30 converts the Section 29 monthly monitoring scorecard into a controlled governance
decision. It assigns green, amber, and red traffic lights; breach ownership; investigation and
remediation dates; model-change and revalidation triggers; monthly sign-off requirements; and
annual independent-validation status.

This project uses public market data and synthetic clearing-member portfolios. The thresholds
below are controlled benchmark thresholds for this repository. They are not represented as
confidential FICC production thresholds, actual participant outcomes, or DTCC policy.

## Controlled deliverables

- `configs/monitoring_governance.yaml`
- `data/manifests/monitoring_threshold_register.csv`
- `src/ficc_liquidity/monitoring/governance.py`
- `scripts/run_monitoring_governance.py`
- `tests/test_monitoring_governance.py`
- `sql/monitoring_governance.sql`
- `reports/monitoring/governance/`

## Traffic-light thresholds

Section 29 computes `PASS`, `WARN`, and `FAIL`. Section 30 maps those results to `GREEN`,
`AMBER`, and `RED` respectively. The controlled quantitative interpretation is:

| Control | Green | Amber | Red |
|---|---|---|---|
| Data completeness | Minimum required-field completeness at least 99.5% | At least 98.0% but below 99.5% | Below 98.0% |
| Schema changes | No schema issue | Not used | Any missing required field or invalid controlled type |
| Missing observations | 0 missing business days | 1–2 missing business days | 3 or more missing business days |
| Historical-range breaches | Breach rate below 1% | At least 1% but below 5% | At least 5% |
| Parameter changes | Relative change below 5% and no structural change | At least 5% but below 15% | At least 15%, or any categorical/add/remove change |
| Exposure concentration | Largest share below 20% and HHI below 0.18 | Largest share 20%–<30% or HHI 0.18–<0.25 | Largest share at least 30% or HHI at least 0.25 |
| LCR distribution | LCR fifth percentile above 1.05, breach rate below 0.1%, and mean drift below 10% | Intermediate range | Fifth percentile at or below 1.00, breach rate at least 1%, or mean drift at least 25% |
| Scenario-rank stability | Rank correlation above 0.90 | Above 0.75 through 0.90 | At or below 0.75 |
| Component-contribution drift | Maximum share change below 5% | At least 5% but below 10% | At least 10% |
| Sensitivity changes | Maximum relative change below 15% | At least 15% but below 30% | At least 30% |
| Reconciliation failures | 0 failures | 1 failure | 2 or more failures |

Where a control combines multiple measures, the worst applicable traffic light governs.

## Escalation standards

| Traffic light | Acknowledge | Investigation | Remediation target | Governance treatment |
|---|---:|---:|---:|---|
| Green | Not required | Not required | Not applicable | Retain evidence and proceed to monthly sign-off |
| Amber | 2 business days | 5 business days | 20 business days | Owner analysis, documented disposition, Model Owner and Model Risk review |
| Red | 1 business day | 2 business days | 10 business days, subject to tighter control-specific limits | Immediate escalation, model-use restriction assessment, management acceptance, and blocked sign-off until disposition |

The YAML file contains tighter red remediation dates for data completeness, schema changes,
parameter changes, LCR distribution, and reconciliation failures.

## Breach ownership

Each control has a named primary and secondary owner. Primary owners perform the investigation
and maintain the evidence package. Secondary owners challenge the analysis, approve the
disposition, and confirm whether model change, use restriction, or revalidation is required.

Every amber or red breach must document:

1. Reproduction from frozen source data and configuration.
2. Source-lineage, schema, parameter, and code-change checks.
3. Quantitative impact on stressed liquidity requirements, available resources, LCR, Cover 1,
   and Cover 2 where relevant.
4. Root cause, interim control, remediation owner, target date, and closure criteria.
5. Independent closure verification for high or critical issues.

## Model-change triggers

A controlled model-change assessment is required when an amber or red result indicates a
potential change to:

- Data schema or controlled input contract.
- Model parameters or parameter structure.
- Liquidity adequacy logic or available-resource treatment.
- Scenario definitions, severity, or rank ordering.
- Stress-component calculation or aggregation.
- Sensitivity behavior.
- Production-to-independent reconciliation.

Any approved change must be classified as non-material or material, version-controlled, tested,
approved before use, and entered in the change log.

## Revalidation triggers

Revalidation is required when any of the following occurs:

- A critical control is red.
- The same control is red twice within the configured three-month lookback.
- The same control is amber three times within the configured six-month lookback.
- A material model change is approved.
- Annual independent validation is overdue or cannot be evidenced.
- Model Risk Management determines that cumulative changes or unresolved findings are material.

Revalidation scope must be proportionate to the trigger. A targeted revalidation may be used for
a localized change; a full validation is required for material methodology, architecture, data,
scenario, or resource-eligibility changes.

## Monthly sign-off

Monthly sign-off is due within 10 business days after month-end and requires:

- Data Owner.
- Model Monitoring Owner.
- Model Owner.
- Model Risk Reviewer.

Green results are ready for signature. Amber results are conditional on documented breach
disposition. Red results block sign-off until the model-use decision, remediation plan, and
management acceptance are documented.

## Annual independent validation

Independent validation must occur at least every 12 months and remain independent from model
development. The minimum scope includes conceptual soundness, independent implementation,
outcomes and benchmarks, sensitivity, uncertainty and limitations, monitoring effectiveness,
and closure testing of prior findings.

The governance engine compares the as-of date with the last completed validation date and
classifies the annual cycle as `CURRENT`, `DUE_SOON`, `OVERDUE`, or `NOT_EVIDENCED`.

## Execution

```powershell
.\.venv\Scripts\python.exe scripts\run_monitoring_governance.py `
  --scorecard reports\monitoring\monthly\monthly_monitoring_scorecard_20260630.csv `
  --history reports\monitoring\governance\governance_history.csv `
  --change-log reports\monitoring\governance\approved_change_log.csv `
  --as-of-date 2026-06-30 `
  --last-validation-date 2026-01-15 `
  --output-dir reports\monitoring\governance
```

Use `--demo` for the deterministic synthetic smoke test. Use `--fail-on-red` when a red result
must return a nonzero process exit code for a CI or operating-control gate.
