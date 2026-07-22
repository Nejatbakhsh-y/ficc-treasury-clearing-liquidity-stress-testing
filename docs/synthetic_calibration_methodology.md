# Phase IV, Section 12 â€” Calibration to Federal Reserve Aggregates

## Purpose

This section allocates selected public FR 2004 aggregate controls across a configurable
set of fictional clearing members. It supports liquidity stress-testing methodology and
implementation validation. It does not estimate actual participant portfolios.

## Mandatory non-identification control

Every generated identifier follows `SYN-MBR-0001` and every label follows
`Fictional Clearing Member 001`. The output sets:

- `value_class = synthetic`;
- `actual_ficc_participant = false`;
- `participant_level_inference = false`.

No dealer name, FICC participant name, market share estimate, regulatory filing, or
participant-specific attribute is used. The allocation is determined only by the configured
random seed, Pareto shape, concentration power, and public aggregate totals.

## Source hierarchy

The implementation uses the first available controlled source:

1. latest immutable FR 2004 raw CSV under `data/raw/fr2004`;
2. latest canonical FR 2004 Parquet file;
3. Section 8 processed Federal Reserve factors.

The official FR 2004 series dictionary is cached locally when available. Series resolution is
recorded in `reports/evidence/fr2004_series_resolution_diagnostic.csv`.

## Aggregate controls

The selected controls are:

- nonnegative Treasury long-position maturity buckets;
- Treasury transaction activity;
- Treasury securities-out financing;
- Treasury securities-in or reverse-repo activity;
- Treasury fails to receive;
- Treasury fails to deliver.

Treasury maturity controls are mutually exclusive within the selected series universe. If the
official descriptions do not permit direct maturity resolution, the selected aggregate
Treasury long-position control is split using the pre-specified fallback shares in the YAML
configuration. The fallback is a transparent model assumption, not an observed participant
distribution.

## Exact allocation

For every control, the procedure:

1. converts the aggregate to integer U.S. cents;
2. generates deterministic Pareto member weights;
3. applies the configured concentration power;
4. applies a deterministic lognormal component perturbation;
5. allocates cents using the largest-remainder method;
6. verifies that allocated cents equal target cents exactly.

This prevents floating-point drift from creating an apparent reconciliation difference.

## Financing and settlement identities

The FR 2004 securities-out and securities-in controls are stock measures, while Treasury
transaction activity is a flow measure. They are therefore retained in separate, clearly
labeled FR 2004 calibration columns and reconciled independently. The member-schema repo
financing need and reverse-repo position are synthetic normalized exposures derived from
the member's allocated transaction activity and observed financing mix. This construction
preserves the Section 11 requirements that funding dependency remain between zero and one
and that reverse-repo positions not exceed repo financing need without mischaracterizing
stock and flow aggregates as an accounting identity.

Settlement fails equal fails to receive plus fails to deliver, with both components retained
and reconciled separately.

## Derived fields

Settlement obligations, stressed liquidity needs, collateral inventory, qualified liquid
resources, coverage ratios, and liquidity-risk scores are synthetic derived quantities. They
are not represented as FR 2004 observations.

## Reproducibility

The random seed, member count, Pareto shape, concentration power, risk weights, source hash,
source observation date, and deterministic record digest are recorded in the manifest and
evidence report. Two independent in-memory generations must have identical digests.

## Completion gates

The implementation cannot report Section 12 as complete unless all five gates pass:

- FR 2004 aggregate reconciliation;
- synthetic member identifiers;
- nonnegative exposures;
- deterministic reproduction;
- no participant-level inference.
