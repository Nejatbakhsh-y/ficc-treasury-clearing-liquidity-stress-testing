# Section 20 â€” Historical Scenarios

## Objective

Section 20 replays the empirically selected historical windows produced by Section 10. It uses the canonical Section 8 Federal Reserve analytical data and the validated Phase V liquidity-stress components. The replay applies observed market conditions only to fictional synthetic clearing members.

## Observed inputs

The engine uses five controlled factor groups:

1. H.15 Treasury yield changes by maturity.
2. SOFR level and spike behavior.
3. FR 2004 and SOFR financing-volume contractions.
4. FR 2004 settlement-fail increases.
5. H.4.1 reserve-balance contractions.

The selected scenario dates and series-selection rules remain controlled by `configs/historical_scenarios.yaml`. Candidate anchors are not substituted for empirically selected windows.

## Replay mechanics

Treasury shocks are replayed directly. For each H.15 series, the engine calculates the change between the latest observed value on or before the scenario start date and the latest observed value on or before the scenario end date. The resulting key-rate changes are converted to basis points and interpolated to the Section 15 maturity buckets. Section 15 then revalues synthetic Treasury positions using its existing duration, convexity, liquidation-horizon, concentration, and market-impact controls.

SOFR, financing, settlement-fail, and reserve-balance conditions are measured from observed data. Their normalized empirical severity score selects the nearest already validated Section 16, Section 17, and Section 18 scenario. This preserves the controlled mechanics of the component models while preventing Section 20 from inventing new participant-level behavior.

Each historical window is passed independently through the Section 19 integrated stress engine. Independent execution avoids imposing a false monotonic ordering across unrelated historical episodes. Section 19 continues to use atomic components and its established double-counting controls.

## Missing-data policy

No unavailable series is backfilled with a synthetic historical observation. A scenario can be marked `PARTIAL` when some factor groups are unavailable, such as SOFR before its publication history. An as-of observation is accepted only within the configured maximum lookback period. All audit observations must be dated on or before the historical scenario end date.

## Outputs

The controlled outputs are:

- `reports/tables/historical_scenario_metrics.csv`
- `reports/tables/historical_treasury_bucket_shocks.csv`
- `reports/tables/historical_factor_observations.csv`
- `reports/tables/historical_component_selections.csv`
- `reports/tables/historical_scenario_member_results.csv`
- `reports/tables/historical_scenario_summary.csv`
- `reports/tables/historical_scenario_double_count_controls.csv`
- `reports/evidence/section20_historical_scenarios.json`
- `reports/evidence/section20_historical_scenarios.md`
- `data/manifests/historical_scenario_manifest.csv`

CSV and Parquet versions are produced where supported.

## Scope safeguard

The model does not identify, estimate, rank, or infer any actual FICC participant. Historical market data are observed public aggregates; member exposures and liquidity results remain synthetic.