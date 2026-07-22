# Section 15 — Treasury Yield-Shock Model

## Purpose

This module translates Federal Reserve H.15 Treasury yield shocks into estimated
changes in synthetic clearing-member Treasury values. It supports the liquidity
stress framework without identifying, estimating, or representing any actual
FICC participant.

## Valuation method

For each synthetic position, the model uses the second-order approximation:

\[
\frac{\Delta P}{P}
\approx
-D_{\mathrm{mod}}\Delta y
+
\frac{1}{2}C(\Delta y)^2
\]

where:

- \(D_{\mathrm{mod}}\) is modified duration;
- \(C\) is convexity;
- \(\Delta y\) is the effective yield shock in decimal form.

The effective shock combines:

1. the configured parallel, curve, key-rate, or H.15 historical shock;
2. square-root-of-time scaling over the maturity-specific liquidation horizon;
3. an adverse market-impact increment based on position size and member
   concentration.

## Scenario coverage

The controlled configuration includes:

- parallel upward and downward shifts;
- bear steepening;
- bear flattening;
- 2-year, 5-year, 10-year, and 30-year key-rate shocks;
- optional historical H.15 start-to-end yield changes.

## Maturity buckets

Every position must map to a controlled maturity bucket. Each bucket has explicit:

- midpoint maturity;
- modified duration;
- convexity;
- liquidation horizon.

Position-level duration, convexity, and horizon values may override defaults when
they are present and valid.

## H.15 historical shock ingestion

The runner can derive a historical yield vector from the processed H.15 dataset:

```powershell
python scripts/run_treasury_yield_stress.py `
  --h15-start-date 2020-03-02 `
  --h15-end-date 2020-03-16
```

The model selects the last available observation on or before each requested date,
converts yield changes to basis points, and interpolates them to maturity-bucket
midpoints.

## Required input

Preferred columns:

| Field | Requirement |
|---|---|
| `member_id` | Synthetic identifier matching the configured pattern |
| `maturity_bucket` | Controlled bucket name |
| `market_value_usd` | Signed market value |
| `as_of_date` | Recommended |
| `modified_duration` | Optional override |
| `convexity` | Optional override |
| `liquidation_days` | Optional override |

A configured par-value proxy is permitted only when market value is unavailable.
The output records the valuation source.

## Outputs

The runner writes:

- `reports/tables/treasury_yield_stress_position_results.csv`
- `reports/tables/treasury_yield_stress_member_summary.csv`
- `reports/tables/treasury_yield_stress_scenario_summary.csv`
- corresponding Parquet files when a Parquet engine is available;
- `reports/evidence/section15_treasury_yield_stress.json`
- `reports/evidence/section15_treasury_yield_stress.md`

Smoke-test outputs include the `_smoke` suffix and must not be interpreted as
production estimates.

## Model-risk limitations

1. Duration-convexity is an approximation and can become inaccurate for large,
   nonparallel shocks or securities with embedded options.
2. Bucket-level assumptions simplify cash-flow and security-specific effects.
3. Public Federal Reserve data do not provide actual FICC member portfolios.
4. Market-impact and liquidation-horizon parameters are modeled assumptions.
5. Historical H.15 changes describe observed Treasury yields, not forced
   liquidation prices or executable stressed spreads.
6. This module estimates Treasury valuation losses. The downstream liquidity
   engine must translate those losses into funding and settlement cash needs.

## Validation controls

Automated tests cover:

- duration-convexity mathematics;
- parallel, steepening, flattening, and key-rate construction;
- liquidation-horizon scaling;
- market-impact monotonicity;
- H.15 basis-point conversion;
- deterministic reproduction;
- synthetic-member labeling;
- member and scenario aggregation.