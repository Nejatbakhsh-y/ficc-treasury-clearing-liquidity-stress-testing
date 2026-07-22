# Section 13 â€” Default-Set Construction Methodology

## Purpose

This component constructs controlled default sets for synthetic clearing-member
liquidity stress testing. It supports Cover 1, Cover 2, concentration-based, and
correlation-based stress scenarios without using or inferring actual FICC
participant identities.

## Synthetic-only control

Every member identifier must satisfy the configured synthetic identifier pattern:

```text
^SYN-MEMBER-[0-9]{4,}$
```

Any actual participant name, participant code, or participant-like identifier is
rejected. The output metadata explicitly records `synthetic_only: true`.

## Default-severity ranking

Members are ranked using a configurable weighted stressed-liquidity score:

```text
default severity
  = stressed liquidity need
  + 0.25 Ã— settlement obligation
  + 0.25 Ã— repo financing need
  âˆ’ available qualified liquid resources
```

The weights are governance assumptions stored in `configs/default_sets.yaml`.
They are not FICC methodology claims. Missing-field handling and zero-floor
behavior are also configuration controlled.

## Default-set definitions

### Largest single-member default

Selects the synthetic member with the largest default-severity score. Ties are
resolved deterministically by ascending synthetic member identifier.

### Cover 1

Uses the same controlled selection as the largest single-member default.

### Largest two-member default

Selects the two synthetic members with the largest default-severity scores.

### Cover 2

Uses the same controlled selection as the largest two-member default.

### Concentrated-member defaults

Selects members at or above the configured concentration threshold. By default,
each qualifying member becomes a separate single-member stress scenario.

### Correlated multi-member defaults

Groups synthetic members by the configured correlation or stress cluster.
Qualifying groups must contain at least two members. Groups are ranked by
aggregate default severity, and each selected group becomes a multi-member
default scenario.

### Explicit governance-defined sets

A disabled template permits controlled member lists to be specified explicitly.
Every listed member must exist in the synthetic portfolio.

## Determinism

All selections use stable sorting:

1. Default severity, descending.
2. Synthetic member identifier, ascending.

Input row order therefore cannot change the output.

## Configuration

Primary configuration:

```text
configs/default_sets.yaml
```

Main fields:

- `scoring.fields`
- `definitions`
- `minimum_concentration`
- `minimum_members`
- `maximum_members_per_group`
- `maximum_groups`
- `synthetic_member_id_pattern`

## Execution

Built-in acceptance test:

```powershell
python -m ficc_liquidity.synthetic.default_sets `
  --self-test `
  --config configs/default_sets.yaml `
  --output reports/tables/default_sets.csv `
  --evidence reports/evidence/section13_default_set_validation.txt
```

Execution against the calibrated Section 12 member portfolio:

```powershell
python -m ficc_liquidity.synthetic.default_sets `
  --members data/processed/synthetic_member_portfolios.parquet `
  --config configs/default_sets.yaml `
  --output reports/tables/default_sets.csv `
  --evidence reports/evidence/section13_default_set_validation.txt
```

## Required acceptance evidence

The final evidence file must state:

```text
Largest single-member default: PASS
Cover 1 selection: PASS
Largest two-member default: PASS
Cover 2 selection: PASS
Concentrated-member defaults: PASS
Correlated multi-member defaults: PASS
Configurable default-set definitions: PASS
Deterministic selection: PASS
Actual FICC participants represented: NO
Synthetic member identifiers only: YES
Section 13: COMPLETE
```

## Limitations

- The default-severity score is a project modeling assumption.
- Correlation clusters are synthetic calibration inputs, not participant facts.
- Cover 1 and Cover 2 identify largest modeled synthetic liquidity exposures;
  they do not reproduce confidential FICC default-management calculations.
- Outputs support research and model-validation testing only.