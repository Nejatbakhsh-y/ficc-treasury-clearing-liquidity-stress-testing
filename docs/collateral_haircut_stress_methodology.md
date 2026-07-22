# Collateral Haircut-Stress Methodology

## Purpose

Phase V, Section 17 measures how collateral haircut increases affect the
liquidity position of fictional synthetic clearing members. The model separates
the haircut mechanism from the Section 15 Treasury price-shock model and the
Section 16 repo funding-stress model so each risk channel can be validated
independently before combined scenario aggregation.

The implementation does not use, identify, represent, rank, or infer any actual
FICC participant. All member-level records are fictional synthetic observations.

## Controlled inputs

The model uses:

- Section 12 calibrated synthetic member portfolios;
- Section 14 baseline liquidity cash flows;
- explicit maturity-bucket haircut assumptions in
  `configs/collateral_haircut_stress.yaml`; and
- explicit scenario, concentration, collateral-call, and inventory-availability
  assumptions.

## Maturity-dependent baseline haircuts

Each Treasury maturity bucket has a controlled baseline haircut and eligibility
factor. Longer-duration collateral receives a larger baseline haircut and may
receive a lower eligibility factor. The default configuration covers:

- bills from zero to one year;
- notes from one to three years;
- notes from three to seven years;
- notes from seven to ten years;
- bonds from ten to thirty years; and
- STRIPS or other Treasury exposures beyond thirty years.

## Stress-dependent haircuts

For member \(i\), maturity bucket \(b\), and scenario \(s\), the stressed
haircut is:

\[
h_{i,b,s} =
\min\left(
h_s^{\max},
\max\left[
h_b,
h_b m_s + a_s + a_{b,s} + c_{i,b,s}
\right]
\right),
\]

where:

- \(h_b\) is the baseline maturity haircut;
- \(m_s\) is the scenario stress multiplier;
- \(a_s\) is the scenario additive haircut;
- \(a_{b,s}\) is the maturity-specific scenario addon; and
- \(c_{i,b,s}\) is the concentration addon.

The stressed haircut cannot fall below the baseline haircut or exceed the
scenario maximum.

## Concentration multiplier

The member's Treasury collateral is converted to maturity-bucket weights. The
concentration addon is:

\[
c_{i,b,s} =
\max(w_{i,b} - \tau_s, 0)\gamma_s,
\]

where \(w_{i,b}\) is the bucket share, \(\tau_s\) is the scenario concentration
threshold, and \(\gamma_s\) is the concentration multiplier. This produces a
larger haircut for concentrated maturity exposures without using participant-
specific information.

## Additional collateral requirement

Repo financing need is allocated across maturity buckets using the synthetic
Treasury collateral weights. Required collateral before and after stress is:

\[
C^{base}_{i,b} = \frac{E_{i,b}}{1-h_b},
\qquad
C^{stress}_{i,b,s} = \frac{E_{i,b}}{1-h_{i,b,s}},
\]

where \(E_{i,b}\) is allocated repo exposure.

The haircut-driven collateral call is:

\[
\Delta C^{haircut}_{i,b,s}
=
\max(C^{stress}_{i,b,s} - C^{base}_{i,b}, 0).
\]

An explicit scenario collateral-call rate is added to capture non-haircut
collateral demands. Total additional collateral requirement equals the
haircut-driven call plus the scenario call.

## Available-collateral constraint

Collateral inventory is allocated across maturity buckets and capped by the
bucket's Treasury market value. Baseline excess inventory is reduced by:

- the maturity eligibility factor;
- the scenario inventory-availability rate; and
- the stressed-to-baseline collateral valuation factor.

Collateral posted cannot exceed stressed available collateral. Any remaining
requirement is a collateral shortfall:

\[
S_{i,b,s}
=
\max(\Delta C_{i,b,s} - A_{i,b,s}, 0).
\]

## Liquidity integration

Haircut value loss, inventory unavailability, and collateral posted reduce
eligible collateral resources. The resource reduction is capped by the
synthetic member's available qualified liquid resources and by the Section 14
baseline eligible-collateral liquidity amount.

Collateral shortfall increases stressed liquidity need. The model recalculates:

- stressed eligible collateral liquidity;
- stressed total available resources;
- stressed liquidity need;
- stressed liquidity headroom;
- stressed liquidity shortfall; and
- stressed liquidity coverage ratio.

## Validation controls

The implementation validates:

- complete member-scenario-maturity output;
- unique scenario, member, and maturity keys;
- finite and nonnegative monetary amounts;
- baseline and maximum haircut bounds;
- additional collateral requirement decomposition;
- collateral-posting limits;
- collateral-shortfall identities;
- liquidity headroom and shortfall identities;
- exact zero-shock control behavior;
- nondecreasing haircut severity;
- complete scenario aggregation;
- deterministic reproduction under input row reordering; and
- synthetic-only member identity controls.

## Limitations

- Haircuts are scenario assumptions rather than observed contractual terms.
- Public aggregate data do not disclose actual participant collateral inventory,
  encumbrance, substitutions, or bilateral haircut schedules.
- Repo exposure is allocated by Treasury maturity weights rather than instrument-
  level financing records.
- The model is a deterministic risk overlay, not an equilibrium model of
  collateral transformation or dealer behavior.
- Results must not be interpreted as estimates for an actual FICC participant.
