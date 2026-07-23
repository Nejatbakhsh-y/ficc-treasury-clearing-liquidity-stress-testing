# Section 22 â€” Cover 1 and Cover 2 Analysis

## Purpose

Section 22 converts the scenario-level synthetic member results produced by the
Phase VI scenario library into reproducible Cover 1 and Cover 2 liquidity
coverage diagnostics. The analysis is performed independently for every
historical or hypothetical scenario present in the controlled input table.

No output identifies, estimates, ranks, or infers an actual FICC participant.
All member identifiers must satisfy the configured synthetic identifier pattern.

## Selection rule

Within each scenario, synthetic members are ranked using:

1. Gross stressed liquidity requirement, descending.
2. Liquidity shortfall, descending.
3. Synthetic member identifier, ascending.

Cover 1 selects the first ranked synthetic member. Cover 2 selects the first two
ranked synthetic members. The deterministic member-identifier tie breaker
ensures that input row order cannot change the selected set.

The ranking rule is a controlled project assumption. It is not presented as a
confidential FICC methodology.

## Metrics

For each scenario and Cover standard:

```text
Cover stressed requirement = sum of selected member stressed requirements
Available resources         = sum of selected member AQLR
LCR                         = available resources / Cover stressed requirement
Liquidity shortfall         = max(Cover stressed requirement - resources, 0)
Resource utilization        = Cover stressed requirement / available resources
```

The analysis also aggregates the atomic Section 19 stress components across the
selected Cover set. The largest aggregated component is reported as the dominant
stress component. The configured component order provides a deterministic tie
breaker.

## Atomic stress components

The controlled component set is:

- Settlement liquidity need.
- Repo rollover need.
- Incremental funding cost.
- Additional haircut requirement.
- Treasury liquidation loss.
- Settlement-fail requirement.
- Concentration adjustment.
- Operational liquidity buffer.

The component sum must reconcile to the Cover stressed requirement within the
configured USD tolerance.

## Outputs

The runner creates:

- `reports/tables/cover_analysis_results.csv` and `.parquet`: one row per
  scenario and Cover standard.
- `reports/tables/cover_analysis_scenario_summary.csv` and `.parquet`: one wide
  row per scenario with explicit Cover 1 and Cover 2 fields.
- `reports/tables/cover_analysis_selected_members.csv` and `.parquet`: selected
  synthetic members and deterministic selection ranks.
- `reports/tables/cover_analysis_component_summary.csv` and `.parquet`: atomic
  component attribution and dominant-component flags.
- `reports/evidence/section22_cover_analysis.json` and `.md`: validation
  evidence.
- `data/manifests/cover_analysis_manifest.csv`: lineage and file-integrity
  metadata.

## Validation gates

The Section 22 run passes only when:

- Every scenario has exactly one Cover 1 row and one Cover 2 row.
- Cover 1 contains one synthetic member.
- Cover 2 contains two distinct synthetic members.
- Cover 2 stressed requirement is not less than Cover 1.
- Shortfall, LCR, and resource-utilization identities are valid.
- Atomic components reconcile to the stressed requirement.
- Exactly one dominant component is identified per scenario and Cover standard.
- Selection is deterministic under input-row shuffling.
- Only controlled synthetic member identifiers are present.
- Actual FICC participants are excluded.

## Limitations

The analysis uses synthetic member AQLR as the available-resource basis because
that is the controlled resource field produced by the existing model. It does
not claim to reproduce confidential legal-entity netting, settlement-bank,
liquidity-provider, or committed-facility arrangements.
