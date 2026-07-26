# Phase IX, Section 33 - Streamlit Dashboard

## Objective

The Section 33 dashboard provides a controlled visual reporting surface for the
FICC Treasury Clearing Liquidity Stress Testing and Model Validation project.

It consolidates public Federal Reserve market information, fictional synthetic
member exposures, model results, validation analysis, monitoring, and governance
evidence. It is not an actual FICC production dashboard.

## Pages

1. Executive summary.
2. Federal Reserve market conditions.
3. Synthetic member exposures.
4. Cover 1 and Cover 2.
5. Historical stress scenarios.
6. Hypothetical scenarios.
7. Liquidity Coverage Ratio.
8. Liquidity shortfalls.
9. Component contributions.
10. Sensitivity analysis.
11. Reverse stress.
12. Model monitoring.
13. Findings and remediation.
14. Limitations and governance.

## Data lineage

The dashboard searches the repository for compatible CSV, Parquet, and JSON files.
The search priority favors:

1. `reports/evidence_package/`
2. `reports/`
3. `data/processed/`
4. `data/analytical/`
5. `data/`

When no compatible artifact is available, the dashboard can display deterministic
fictional fallback data. Every fallback view is explicitly labelled as demonstration
data. Disable fallback data by setting:

```powershell
$env:FICC_DASHBOARD_ALLOW_DEMO = "0"
```

## Run in VS Code

From the repository root:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\.venv\Scripts\python.exe -m streamlit run dashboard\streamlit_app.py
```

Alternative controlled launcher:

```powershell
.\.venv\Scripts\python.exe scripts\run_dashboard.py
```

Strict evidence-only mode:

```powershell
.\.venv\Scripts\python.exe scripts\run_dashboard.py --no-demo
```

## Validation

The automation performs:

- Python compilation.
- Ruff formatting and linting.
- Strict Mypy validation of the dashboard support module.
- Focused Pytest and Streamlit AppTest execution.
- Optional complete repository test suite.
- Headless Streamlit server health check.
- Controlled validation evidence generation.

## Model-risk restrictions

- All member identifiers are synthetic.
- No page may identify, infer, or approximate an actual FICC participant.
- Public Federal Reserve aggregate data do not provide participant-level or complete
  intraday liquidity information.
- Dashboard values must not be represented as actual FICC production outcomes.
- Synthetic fallback data are for implementation verification only.
- Material model limitations and unresolved findings must remain visible to users.
