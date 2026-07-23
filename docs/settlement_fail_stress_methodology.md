# Section 18 â€” Settlement-Fail Stress

## Purpose

This module applies controlled settlement-fail shocks to the Phase V liquidity
cash-flow framework. It operates only on fictional synthetic member records and
does not identify, estimate, rank, or infer any actual FICC participant.

## Implemented channels

1. **Fails to receive.** Expected incoming settlement payments are subjected to
   scenario-specific fail multipliers and incremental fail rates.
2. **Fails to deliver.** Gross settlement obligations are subjected to separate
   deliver-fail assumptions, bounded by the obligation in each time bucket.
3. **Delayed incoming payments.** Failed receipts create an immediate liquidity
   need and are recovered only after the configured number of time buckets. A
   delay beyond the modeled horizon remains unrecovered during the horizon.
4. **Required replacement liquidity.** Deliver fails generate replacement
   liquidity equal to the failed amount times the configured replacement rate.
5. **Persistent multi-day fails.** A geometric persistence factor converts fail
   balances into additional carrying liquidity and explicit daily penalties.
6. **Combined settlement and funding shocks.** Each settlement scenario maps to
   a Section 16 repo-funding scenario. The model imports Section 16 incremental
   funding outflows and applies the controlled combination weight.

## Core calculations

For each member and time bucket, the model calculates bounded fails to receive
and fails to deliver. The incremental settlement-fail outflow is:

```text
delayed receipt need
+ replacement liquidity
+ persistent fail liquidity
+ deliver-fail penalty
```

The combined incremental outflow adds the weighted Section 16 funding-stress
outflow. Stressed liquidity need is then recomputed in chronological order using
a zero floor, and stressed headroom equals available resources minus stressed
cumulative liquidity need.

## Inputs

Preferred controlled inputs are:

- `reports/tables/baseline_liquidity_cashflows.parquet`
- `data/synthetic/calibrated_member_portfolios.parquet`
- `reports/tables/repo_funding_stress_cashflows.parquet`

The member dataset must provide `settlement_obligation_usd`,
`settlement_fail_usd`, and a consistent `settlement_fail_rate` when that ratio is
present. The funding dataset must provide Section 16 scenario, member, bucket,
and incremental repo-funding stress outflow fields.

## Outputs

The runner writes CSV and Parquet versions of:

- `reports/tables/settlement_fail_stress_cashflows`
- `reports/tables/settlement_fail_stress_member_summary`
- `reports/tables/settlement_fail_stress_scenario_summary`

It also writes:

- `reports/evidence/section18_settlement_fail_stress.json`
- `reports/evidence/section18_settlement_fail_stress.md`
- `data/manifests/settlement_fail_stress_manifest.csv`

## Model-risk limitations

- Fail splits, incremental fail rates, delays, persistence, replacement rates,
  penalties, and funding-combination weights are explicit assumptions.
- Public aggregate data do not reveal actual participant-level settlement fails,
  bilateral counterparties, operational causes, or contractual remedies.
- Delayed receipts are modeled as liquidity timing shocks, not credit losses.
- Replacement liquidity is a conservative cash requirement, not a prediction of
  an actual buy-in, close-out, or contractual settlement process.
- Section 16 funding outflows are imported scenario overlays and do not infer
  lender identities or bilateral financing terms.
