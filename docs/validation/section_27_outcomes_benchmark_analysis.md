# Section 27 - Outcomes and Benchmark Analysis

## Objective

Validate model behavior when realized FICC outcome data are unavailable. The validation does not infer participant-level outcomes and does not represent controlled synthetic evidence as empirical FICC calibration.

## Required analyses

1. Historical plausibility through bounded values, accounting identities, and economically coherent stress responses.
2. Scenario rank ordering across baseline, moderate, severe, and extreme scenarios.
3. Monotonicity for yield shocks, duration, SOFR spikes, rollover failure, haircuts, settlement fails, concentration, liquidation horizon, default-set size, and available resources.
4. Independent deterministic challenge calculations using exposures and stress drivers without calling production calculation functions.
5. Component reconciliation between reported total requirement and the additive stress components.
6. Stability across deterministic random seeds.
7. Comparison with a simpler deterministic benchmark.
8. Tail behavior using requirement, shortfall, and LCR quantiles.
9. Economic interpretation based on dominant components and shortfall frequency.

## Evidence modes

- `external_model_output`: analyzes a supplied CSV, JSON, or JSONL file.
- `controlled_benchmark`: generates reproducible validation data solely to test the validation framework. Its successful result is labeled `PASS_CONTROLLED_ONLY`.

## Canonical external-output fields

The loader accepts common aliases, but the preferred fields are:

- `scenario_id`, `scenario_name`, `analysis_family`, `severity`, `seed`
- `stressed_requirement`, `available_resources`, `lcr`, `shortfall`, `resource_utilization`
- Eight stress-component columns defined by Section 19
- Ten sensitivity-driver columns defined by Section 26
- `settlement_obligation`, `repo_maturity`, `collateral_value`, and `treasury_market_value` for the independent deterministic challenger

Missing inputs cause the associated gate to be marked `NOT_EVALUATED` rather than being imputed as evidence.

## Execution

```powershell
.\.venv\Scripts\python.exe scripts\run_section27.py
```

External model outputs:

```powershell
.\.venv\Scripts\python.exe scripts\run_section27.py `
  --input reports\scenario_analysis\scenario_results.csv `
  --require-external-input
```

## Outputs

All outputs are written to `reports/validation/section27/`, including normalized outcomes, test-level CSV evidence, a JSON summary, and a Markdown validation report.