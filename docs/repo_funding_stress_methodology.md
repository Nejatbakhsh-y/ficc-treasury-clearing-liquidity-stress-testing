# Repo Funding-Stress Model Methodology

## Purpose

Phase V, Section 16 overlays repo-market funding stress on the controlled
Section 14 baseline liquidity cash-flow engine. The model measures how higher
SOFR, wider funding spreads, failed repo rollovers, lender withdrawal, shorter
refinancing horizons, collateral calls, and member funding concentration alter
time-bucketed liquidity needs, headroom, and shortfalls.

The model operates only on fictional synthetic clearing-member records. It does
not identify, represent, rank, or infer any actual FICC participant or bilateral
repo lender.

## Controlled inputs

The runner uses:

- `reports/tables/baseline_liquidity_cashflows.csv` or Parquet from Section 14;
- `data/synthetic/calibrated_member_portfolios.parquet` from Section 12;
- the latest usable SOFR observation in the processed Federal Reserve dataset,
  when available;
- `configs/repo_funding_stress.yaml` for explicit scenario assumptions.

When a usable SOFR observation is unavailable, the runner uses the separately
identified assumed fallback in the configuration and records that fallback in
the evidence file.

## Stress mechanics

For member \(i\), time bucket \(t\), and scenario \(s\), the model starts from
the Section 14 repo amount expected to roll, \(R_{i,t}\).

### Funding unavailability

The base one-cycle funding-unavailability probability combines rollover failure
and lender withdrawal:

\[
u_s = 1 - (1-f_s)(1-w_s),
\]

where \(f_s\) is the repo-rollover failure rate and \(w_s\) is the lender
withdrawal rate.

The model then applies explicit member concentration and funding-dependency
multipliers:

\[
\tilde u_{i,s} =
\min\left(
u_s C_{i,s} D_{i,s},
u_s^{\max}
\right).
\]

The refinancing-cycle multiplier is the baseline liquidity horizon divided by
the stressed refinancing horizon. Effective unavailability is:

\[
U_{i,s} =
\min\left(
1-(1-\tilde u_{i,s})^{N_s},
u_s^{\max}
\right).
\]

The failed rollover outflow is \(R_{i,t}U_{i,s}\).

### SOFR and funding-cost shock

The stressed reference rate is the reference SOFR plus the scenario SOFR shock.
The stressed all-in rate also includes the scenario funding-spread increase.
Incremental funding cost is calculated on successfully refinanced repo using an
annualized Actual/360-style approximation over the baseline liquidity horizon.

### Increased collateral demand

Additional collateral demand includes:

1. an increased haircut applied to successfully refinanced repo and amplified
   by the concentration factor; and
2. an additional collateral or margin call applied to repo maturities and
   amplified by funding dependency.

### Liquidity aggregation

Incremental repo funding-stress outflow is the sum of:

- failed rollover outflow;
- incremental funding cost; and
- additional collateral demand.

The model accumulates this incremental outflow through the Section 14 payment
buckets and recalculates stressed liquidity need, headroom, shortfall, and
coverage.

## Controlled scenarios

The default configuration includes:

- a zero-shock control;
- moderate market stress;
- severe market stress; and
- a concentrated funding freeze.

All parameters are configurable. Scenario ranks, names, and enabled states are
validated, and no enabled scenario can use a refinancing horizon longer than
the baseline horizon.

## Validation controls

The Section 16 implementation validates:

- all seven required stress channels;
- complete scenario-member-time-bucket output;
- unique scenario/member/time-bucket keys;
- nonnegative stress components;
- SOFR and all-in rate identities;
- rollover failure bounded by the baseline roll amount;
- exact stress-component decomposition;
- stressed need, headroom, and shortfall identities;
- deterministic reproduction independent of input row order; and
- synthetic-only member identity controls.

## Limitations

- The model is a deterministic scenario overlay, not a behavioral equilibrium
  model of the repo market.
- Funding costs use a simplified day-count approximation rather than
  instrument-level contractual repricing.
- Bilateral lender identities, contractual haircuts, maturity terms, and
  participant-specific liquidity resources are unavailable in public aggregate
  data.
- Concentration and dependency multipliers are model assumptions requiring
  sensitivity analysis and independent validation.
- Section 16 results must not be interpreted as estimates for any actual FICC
  participant.
