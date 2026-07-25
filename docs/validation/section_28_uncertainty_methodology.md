# Section 28 - Uncertainty and Limitations Methodology

## Objective

Assess the uncertainty and residual model risk created by public aggregate data,
synthetic clearing-member allocations, judgmental scenarios and parameters, missing
intraday information, unavailable participant-level data, simplified operational and
legal assumptions, and simplified Treasury liquidation functions.

## Required uncertainty categories

1. Aggregate-data uncertainty.
2. Synthetic allocation uncertainty.
3. Scenario-selection uncertainty.
4. Parameter uncertainty.
5. Missing intraday information.
6. Participant-level data limitations.
7. Operational and legal assumptions.
8. Model risk from simplified liquidation functions.

## Assessment structure

Each uncertainty source contains:

- a definition and evidence gap;
- the expected model effect;
- probability and impact scores on controlled five-point scales;
- mitigation effectiveness;
- inherent and residual risk ratings;
- quantitative requirement and resource ranges;
- documented limitations, controls, validation actions, and ownership.

## Quantitative envelope

The quantitative assessment uses an illustrative synthetic baseline and two views:

- one-at-a-time favorable and adverse settings for every uncertainty driver;
- a deterministic-seed Monte Carlo envelope using triangular ranges and bounded,
  weighted additive adjustments.

The liquidity coverage ratio is defined as:

```text
LCR = Available Qualified Liquid Resources / Stressed Liquidity Requirement
```

An LCR below 1.0 indicates a modeled liquidity shortfall.

The quantitative envelope is not a calibrated probability model. Its purpose is to
identify sensitivity, rank uncertainty drivers, expose false precision, and support
use restrictions and remediation prioritization.

## Interpretation controls

All inputs are illustrative. No synthetic member represents an actual FICC participant.
The results must not be used for participant-level decisions, regulatory thresholds,
legal conclusions, production limits, or claims about actual FICC resources or exposures.

## Validation gate

Section 28 passes when:

- all eight required uncertainty categories are represented;
- qualitative inherent and residual risk ratings are generated;
- one-at-a-time and joint uncertainty results are reproducible;
- adverse requirement or resource assumptions do not improve LCR;
- a controlled uncertainty register, quantitative summaries, figures, and report are produced;
- prohibited uses and production-data requirements are stated explicitly;
- Pytest, Ruff, and Mypy checks pass for the new implementation.
