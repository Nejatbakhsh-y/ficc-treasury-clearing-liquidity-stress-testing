# Baseline Liquidity Cash-Flow Engine

## Purpose

Phase V, Section 14 establishes the unstressed liquidity cash-flow engine used as the reference point for later historical, hypothetical, reverse, Cover 1, and Cover 2 stress tests. The engine operates only on fictional `SYN-MBR-####` clearing-member portfolios. It does not represent, estimate, rank, identify, or reverse engineer any actual FICC participant.

## Value classification

| Element | Classification | Treatment |
|---|---|---|
| Calibrated member portfolio fields | Synthetic | Generated in Phase IV from public aggregate controls. |
| Payment timing, netting, roll, recognition, cash-share, haircut, and operational-availability parameters | Assumed | Controlled in `configs/baseline_liquidity.yaml`. |
| Time-bucketed cash flows, cumulative needs, resources, headroom, shortfalls, and coverage ratios | Modeled | Deterministic outputs of the Section 14 engine. |

## Modeled components

The engine produces one row per synthetic member and payment-time bucket. It models:

- gross and net settlement cash obligations;
- repo maturities and the portion not rolled at maturity;
- recognized reverse-repo financing inflows;
- financing outflows after the baseline roll assumption;
- available cash at the start of the horizon;
- eligible collateral market value and post-haircut liquidity;
- settlement and financing netting assumptions;
- configurable payment timing over a 48-hour liquidity horizon;
- cumulative net liquidity need, available resources, headroom, and shortfall;
- available qualified liquid resources and the resulting baseline liquidity-coverage ratio.

## Core equations

For member `i` and time bucket `t`:

```text
gross settlement(i,t) = settlement obligation(i) Ã— settlement schedule(t)
net settlement(i,t) = gross settlement(i,t) Ã— (1 - settlement netting rate)
repo maturity(i,t) = repo financing need(i) Ã— repo maturity schedule(t)
financing outflow(i,t) = repo maturity(i,t) Ã— (1 - repo roll rate)
financing inflow(i,t) = reverse repo(i) Ã— recognition rate Ã— inflow schedule(t)
```

When financing netting is enabled, inflows and outflows are offset within each bucket before the residual is included in cash need. Cumulative net liquidity need is floored at zero. Available cash is recognized at the opening bucket. Eligible collateral liquidity is recognized according to the configured operational timing schedule after the configured haircut.

The source AQLR amount is decomposed into available cash and post-haircut eligible collateral liquidity without double counting. The default assumptions are selected so that the modeled decomposition reconciles to source AQLR to the configured USD tolerance.

## Validation controls

The implementation requires:

- complete and unique member-time buckets;
- strictly increasing payment times within the horizon;
- exact settlement-obligation reconciliation;
- exact repo-maturity reconciliation;
- financing inflow and outflow reconciliation;
- AQLR and eligible-collateral timing reconciliation;
- nonnegative gross cash-flow components;
- exact liquidity-shortfall identity;
- deterministic results independent of input row order;
- synthetic identifiers only, with no participant-level inference.

## Limitations

This is a baseline cash-flow model, not a legal interpretation of FICC rules and not a participant-level exposure model. Payment schedules, netting rates, repo roll rates, recognition rates, collateral haircuts, operational availability, and cash composition are explicit assumptions. Later phases should stress these assumptions rather than treating them as observed facts.
