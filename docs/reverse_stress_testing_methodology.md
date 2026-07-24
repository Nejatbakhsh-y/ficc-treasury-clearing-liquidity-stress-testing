# Section 23 — Reverse Stress Testing

## Purpose

Section 23 determines the smallest controlled stress that causes the liquidity
coverage ratio (LCR) to fall below `1.0` or creates a positive liquidity
shortfall. The analysis operates exclusively on fictional synthetic
clearing-member records.

The implementation reuses the validated Section 15, Section 16, Section 17,
and Section 19 engines. It does not infer, reconstruct, rank, or represent any
actual FICC participant.

## Reverse-stress questions

The engine solves five required questions:

1. Minimum parallel Treasury yield shock producing a member LCR below `1.0`.
2. Minimum repo rollover-failure rate producing a member shortfall.
3. Minimum additive Treasury-collateral haircut increase producing a member
   shortfall.
4. Minimum normalized combined scenario producing a member-combination
   shortfall.
5. Most vulnerable synthetic member combination at the combined threshold.

## Controlled starting point

The Section 19 `control` scenario supplies, for each synthetic member:

```text
Control stressed liquidity requirement
Available qualified liquid resources
```

For an evaluated reverse-stress point:

```text
Stressed requirement
= Control stressed requirement
+ Treasury liquidation loss
+ Repo rollover need
+ Additional haircut requirement
```

The member liquidity measures are:

```text
LCR = Available qualified liquid resources / Stressed requirement

Liquidity shortfall
= max(Stressed requirement - Available qualified liquid resources, 0)
```

A breach occurs when either:

```text
LCR < 1.0
```

or:

```text
Liquidity shortfall > configured USD tolerance
```

The strict inequality preserves the policy boundary: an LCR exactly equal to
`1.0` is not classified as below the threshold.

## Exact isolated component evaluation

### Yield shock

The yield search runs the Section 15 duration-and-convexity valuation engine
for a parallel upward Treasury yield shock. Market impact is disabled by
default during the isolated search so the solved parameter is attributable to
the yield shock itself. It can be enabled in configuration.

### Rollover failure

The rollover search runs the Section 16 repo funding-stress engine with only
the rollover-failure channel active. SOFR shock, funding spread, lender
withdrawal, collateral calls, concentration amplification, and dependency
amplification are set to zero.

### Haircut increase

The haircut search runs the Section 17 collateral haircut engine with only an
additive haircut increase active. Stress multipliers, bucket-specific add-ons,
concentration add-ons, additional collateral calls, and inventory
unavailability are neutralized.

This design prevents an isolated threshold from silently including unrelated
stress channels.

## Combined reverse scenario

The combined scenario uses a normalized severity parameter `s` between zero
and one:

```text
Parallel yield shock       = s × configured maximum yield shock
Rollover-failure rate      = s × configured maximum rollover-failure rate
Additive haircut increase  = s × configured maximum haircut increase
```

Each component is recalculated through its original model at every search
point. The combined requirement is not estimated by proportionally scaling a
previous result.

## Member combinations

The default combination size is two members. For each pair:

```text
Pair stressed requirement = sum(member stressed requirements)
Pair available resources  = sum(member available resources)
Pair LCR                   = pair resources / pair requirement
Pair shortfall             = max(pair requirement - pair resources, 0)
```

No cross-member netting, resource transfer, or diversification credit is
assumed. The combination with the lowest LCR, then the largest shortfall, is
ranked as most vulnerable.

## Threshold search

Each reverse test uses a monotone binary search:

1. Evaluate the configured lower bound.
2. Evaluate the configured upper bound.
3. Return `BREACH_AT_LOWER_BOUND` when the control point already breaches.
4. Return `NOT_REACHED` when the upper bound remains covered.
5. Otherwise, repeatedly bisect the safe and breaching bounds.
6. Stop when their distance is no greater than the configured parameter
   tolerance or the iteration cap is reached.

A successful threshold records both the last safe lower bound and first
breaching upper bound. The reported minimum threshold is the breaching upper
bound, making the result conservative within the configured numerical
tolerance.

## Outputs

The controlled runner writes:

- `reports/tables/reverse_stress_thresholds.csv`
- `reports/tables/reverse_stress_member_details.csv`
- `reports/tables/reverse_stress_member_combination_ranking.csv`
- `reports/tables/reverse_stress_search_trace.csv`
- Parquet counterparts when PyArrow is available.
- `reports/evidence/section23_reverse_stress_testing.json`
- `reports/evidence/section23_reverse_stress_testing.md`
- `data/manifests/reverse_stress_testing_manifest.csv`

## Validation gates

The Section 23 gate requires:

- Four required threshold searches completed.
- Safe and breaching bounds reconciled within tolerance.
- Finite and nonnegative required outputs.
- Stressed-requirement accounting identity passed.
- Most vulnerable member combination identified.
- Deterministic reproduction passed.
- Exact Section 15–17 model reuse confirmed.
- All Section 19 control members covered.
- Synthetic-only identifiers and classification controls passed.

## Limitations

Reverse-stress thresholds depend on the controlled synthetic portfolios,
resource assumptions, liquidity horizon, maturity mapping, and configured
search bounds. A `NOT_REACHED` result means only that no breach occurred
within the tested range; it does not establish that no larger shock could
produce a breach.
