# Section 26 â€” Sensitivity Analysis

## Objective

Section 26 independently challenges the stability and directional behavior of the liquidity stress model across ten material assumptions:

1. Treasury yield shocks.
2. Modified-duration assumptions.
3. SOFR spikes.
4. Repo rollover-failure percentages.
5. Collateral haircut increases.
6. Settlement-fail percentages.
7. Member concentration.
8. Liquidation horizon.
9. Default-set size.
10. Available qualified liquid-resource assumptions.

## Independence boundary

The Section 26 validator uses the flat-file calculation path established in Section 25. It imports only the Section 25 independent calculation functions and does not call the production stress engines. This preserves a calculation boundary between validation analysis and production implementation.

## Sensitivity design

Each sensitivity contains a controlled, ordered grid with an explicit baseline. The validator recalculates member stress, generalized Cover N default sets, qualified resources, LCR, liquidity shortfalls, resource utilization, and the dominant stress component.

For every sensitivity point, the analysis records:

- stressed liquidity requirement;
- available qualified liquid resources;
- LCR;
- liquidity shortfall;
- resource utilization;
- selected default members;
- dominant stress component;
- percentage change from baseline;
- requirement and LCR elasticity;
- LCR-breach and shortfall indicators;
- default-set and dominant-component changes.

## Directional expectations

The controlled configuration requires worsening member-stress assumptions to produce nondecreasing stressed requirements and nonincreasing LCRs. Increasing available-resource assumptions must leave the denominator unchanged while producing nondecreasing resources and LCR. Increasing default-set size must produce a nested default set, nondecreasing requirement, nonincreasing available resources, and nonincreasing LCR.

Resource direction is unconstrained for member-stress sensitivities because rank changes can alter which member-owned resources are excluded. The LCR direction remains explicitly tested.

## Liquidation-horizon assumption

The Section 25 flat-file contract does not contain a separate liquidation-horizon field. Section 26 therefore applies a transparent square-root-of-time scaling to the Treasury yield shock around a five-day baseline:

`effective shock = baseline shock Ã— sqrt(test horizon / 5 days)`

This is a validation assumption, not a claim that the production model uses this exact scaling. It is documented so that future production-output comparisons can replace the proxy with the production liquidation-horizon implementation.

## Default-set-size analysis

The validator generalizes Cover 1 and Cover 2 to Cover N. Members are ranked by independently calculated stressed liquidity requirement with deterministic member-ID tie-breaking. Qualified resources owned by defaulting members are excluded.

## Outputs

- `reports/tables/section26_sensitivity_detailed.csv`
- `reports/tables/section26_sensitivity_summary.csv`
- `reports/tables/section26_sensitivity_baselines.csv`
- `reports/tables/section26_sensitivity_findings.csv`
- `reports/evidence/section26_sensitivity_summary.json`
- `reports/evidence/section26_sensitivity_analysis.txt`

## Acceptance criteria

- All ten required sensitivities are configured and executed.
- Baseline results reproduce the Section 25 independent calculation path.
- Directional and monotonicity controls pass.
- Default sets are deterministic and nested as size increases.
- Fraction-based assumptions remain within valid bounds.
- Available-resource shocks do not change stressed requirements.
- Repeated runs are deterministic.
- Source inputs remain unchanged.
- Evidence and findings are written for model-validation review.