# Section 18 Settlement-Fail Stress Evidence

- Generated at (UTC): 2026-07-23T01:14:39.743047+00:00
- Run type: CONTROLLED_MODEL_RUN
- Baseline source: `C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing\reports\tables\baseline_liquidity_cashflows.csv`
- Synthetic member source: `C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing\data\synthetic\calibrated_member_portfolios.parquet`
- Section 16 funding source: `C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing\reports\tables\repo_funding_stress_cashflows.csv`
- Cash-flow scenario rows: 960
- Result SHA-256: `9f4f1aeda286adad31c90bb2c9bea224676ea1a5652fdeb28041e8baf2e6289c`

## Completion gates

- complete_cashflow_matrix: **PASS**
- complete_member_matrix: **PASS**
- unique_cashflow_keys: **PASS**
- finite_nonnegative_stress_amounts: **PASS**
- fails_to_receive_bounds: **PASS**
- fails_to_deliver_bounds: **PASS**
- replacement_liquidity_identity: **PASS**
- delayed_payment_recovery_bounds: **PASS**
- combined_stress_identity: **PASS**
- liquidity_headroom_identity: **PASS**
- zero_shock_control: **PASS**
- severity_monotonicity: **PASS**
- section16_funding_combination: **PASS**
- scenario_aggregation_complete: **PASS**
- synthetic_identity_controls: **PASS**
- deterministic_reproduction: **PASS**

## Scope limitation

All member records are fictional and synthetic. No output identifies,
represents, ranks, or infers an actual FICC participant.
