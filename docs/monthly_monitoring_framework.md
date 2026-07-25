# Section 29 ÃƒÂ¢Ã¢â€šÂ¬Ã¢â‚¬Â Monthly Monitoring Framework

## Objective

This framework provides repeatable monthly monitoring for the FICC Treasury clearing
liquidity stress-testing model. It is designed for synthetic member data and public-source
market inputs. It must not be represented as monitoring of actual FICC participants or
confidential FICC production outcomes.

## Monitoring controls

| Control | Primary measure | Governance purpose |
|---|---|---|
| Data completeness | Minimum non-null rate across required fields | Detect incomplete monthly inputs |
| Schema changes | Missing fields and invalid data types | Enforce the controlled data contract |
| Missing observations | Missing business dates | Identify breaks in input time series |
| Historical-range breaches | Share outside baseline quantile bounds | Detect unusual or potentially invalid values |
| Parameter changes | Maximum relative parameter change | Identify unapproved model/configuration changes |
| Exposure concentration | Largest-member share and HHI | Monitor synthetic portfolio concentration |
| LCR distribution | 5th percentile, breach rate, mean drift | Monitor lower-tail liquidity adequacy |
| Scenario rank stability | Correlation of scenario severity ranks | Detect unexpected scenario ordering changes |
| Component contribution drift | Maximum contribution-share change | Detect changes in stress drivers |
| Sensitivity changes | Maximum relative sensitivity change | Detect response-function instability |
| Reconciliation failures | Failed independent reconciliations | Detect implementation or aggregation breaks |

## Inputs

The monthly result dataset requires these fields:

- `date`
- `member_id`
- `scenario`
- `exposure`
- `stressed_liquidity_requirement`
- `available_resources`
- `lcr`

The component-drift control uses the eight Section 19 stress components when present.
The monitoring run also accepts a historical baseline, the previous monthly result set,
current and prior parameter snapshots, sensitivity snapshots, and reconciliation results.
CSV and Parquet tables are supported. Parameter snapshots may be YAML or JSON.

## Outputs

Each run writes:

1. A CSV control scorecard.
2. A JSON run summary.
3. A Markdown monitoring report.

Outputs are written under `reports/monitoring/monthly/` by default and use the as-of date
in each filename.

## Status and escalation

- **PASS**: retain the evidence package and continue the normal monitoring cycle.
- **WARN**: assign an owner, document the explanation and disposition, and resolve or
  escalate within 10 business days.
- **FAIL**: open a model-risk or data-quality issue before the next production-equivalent
  run. Assess whether model use should be restricted until remediation and independent
  verification are complete.

Any missing monitoring input is treated as a warning rather than silently passing.
Thresholds are controlled in `configs/monitoring.yaml`; all threshold changes must be
reviewed, approved, version-controlled, and included in the monthly evidence package.

## Monthly operating procedure

1. Freeze the current-month analytical dataset and record its lineage.
2. Retain the prior-month dataset and historical baseline used for comparison.
3. Export controlled model parameters and sensitivity results.
4. Run independent reconciliation checks from Section 25.
5. Execute `scripts/run_monthly_monitoring.py`.
6. Review all warnings and failures, assign owners, and document dispositions.
7. Archive the scorecard, summary, report, source hashes, configuration, and approval.
8. Present unresolved issues and trend changes to the model owner and model-risk function.

## Example command

```powershell
.\.venv\Scripts\python.exe scripts\run_monthly_monitoring.py `
  --current data\processed\monthly_results_2026_06.parquet `
  --previous data\processed\monthly_results_2026_05.parquet `
  --baseline data\processed\historical_monitoring_baseline.parquet `
  --current-parameters configs\parameters_2026_06.yaml `
  --previous-parameters configs\parameters_2026_05.yaml `
  --current-sensitivity reports\validation\sensitivity_2026_06.csv `
  --previous-sensitivity reports\validation\sensitivity_2026_05.csv `
  --reconciliation reports\validation\reconciliation_2026_06.csv `
  --as-of-date 2026-06-30
```

Use `--demo` for the deterministic synthetic smoke test.
