# Section 16 Repo Funding-Stress Evidence

- Run timestamp (UTC): 2026-07-22T17:50:29.854741+00:00
- Run type: CONTROLLED_MODEL_RUN
- Baseline source: `C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing\reports\tables\baseline_liquidity_cashflows.csv`
- Synthetic member source: `C:\Users\nejat\OneDrive\Desktop\UN\Skills\GitHub 2026\ficc-treasury-clearing-liquidity-stress-testing\data\synthetic\calibrated_member_portfolios.parquet`
- SOFR source: `ASSUMED_CONFIG_FALLBACK_AFTER_fed_liquidity_factors.parquet`
- Reference SOFR: 4.5000 percent
- Cash-flow scenario rows: 960
- Result SHA-256: `096b864aee6314bce6e3b0919a2665dc353ae8d3d937a3edd1ae2a4f24af6cfb`

## Completion gates

- Sofr Rate Spikes Implemented: **PASS**
- Funding Cost Increases Implemented: **PASS**
- Repo Rollover Failures Implemented: **PASS**
- Partial Lender Withdrawal Implemented: **PASS**
- Shorter Refinancing Horizons Implemented: **PASS**
- Increased Collateral Demands Implemented: **PASS**
- Funding Concentration Implemented: **PASS**
- Scenario Cashflow Rows Complete: **PASS**
- Member Scenario Rows Complete: **PASS**
- Scenario Summary Complete: **PASS**
- Unique Scenario Member Buckets: **PASS**
- Nonnegative Stress Components: **PASS**
- Sofr Rate Identity: **PASS**
- All In Funding Rate Identity: **PASS**
- Rollover Failure Bounded By Roll Amount: **PASS**
- Funding Stress Decomposition Identity: **PASS**
- Stressed Liquidity Need Identity: **PASS**
- Stressed Need Not Below Baseline: **PASS**
- Stressed Headroom Identity: **PASS**
- Stressed Shortfall Identity: **PASS**
- Synthetic Members Only: **PASS**
- Deterministic Reproduction: **PASS**

## Scope limitation

All member records are fictional and synthetic. No output identifies, represents, or infers an actual FICC participant or bilateral lender.
