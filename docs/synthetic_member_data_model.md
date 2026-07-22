# Synthetic Clearing-Member Data Model

## Purpose

This controlled data model supports public-data research, liquidity stress testing,
scenario analysis, and independent model validation. It creates fictional clearing-member
profiles because public Federal Reserve datasets do not disclose the complete member-level
positions, settlement obligations, collateral, or liquidity resources required for a
member-specific FICC liquidity model.

## Mandatory non-identification control

Every record is synthetic. No record represents, approximates, ranks, identifies, or
purports to describe an actual FICC participant. Member identifiers use only the controlled
patterns `SYN-MBR-0001` and `Fictional Clearing Member 001`. The schema rejects any record
marked as an actual FICC participant and rejects labels outside the fictional naming pattern.

Synthetic results must be presented as methodological illustrations, not as estimates of
individual firms.

## Dataset grain

One row represents one fictional clearing member at one controlled as-of date. All monetary
amounts are denominated in U.S. dollars. The initial controlled dataset contains the member
count specified in `configs/synthetic_members.yaml` and uses deterministic seed `2026`.

## Core dimensions

### Treasury inventory and activity

- Treasury positions are allocated across six maturity buckets.
- Total Treasury position reconciles exactly to the maturity-bucket positions.
- Treasury transaction activity represents gross modeled activity over the observation
  horizon.
- Member concentration is the largest maturity-bucket position divided by total Treasury
  positions.

### Secured financing

- Repo financing need represents modeled cash funding required against Treasury activity.
- Reverse-repo position represents modeled cash deployment or offsetting secured financing.
- Funding dependency measures repo financing need relative to Treasury transaction activity.
- Net repo dependency measures the unoffset portion of repo financing need.

### Settlement and fails

- Settlement obligation represents modeled payment or delivery requirements.
- Settlement fail amount cannot exceed the corresponding settlement obligation.
- Settlement-fail rate equals settlement fails divided by settlement obligations.

### Collateral and qualified liquid resources

- Collateral inventory is the modeled pool available to support obligations.
- Available qualified liquid resources are a controlled subset of collateral inventory.
- Stressed liquidity need applies a configurable multiplier to modeled obligations and
  secured-financing needs.
- Liquidity gap is the positive difference between stressed liquidity need and available
  qualified liquid resources.

### Liquidity-risk characteristics

The controlled risk score combines:

1. maturity concentration;
2. funding dependency;
3. settlement-fail intensity;
4. collateral shortfall;
5. qualified-liquid-resource shortfall.

The weights and thresholds are specified before model execution in
`configs/synthetic_members.yaml`. Risk bands are `moderate`, `elevated`, and `high`.

## Field dictionary

| Field group | Principal fields | Control |
|---|---|---|
| Identity | `member_id`, `member_label` | Generic fictional patterns only |
| Provenance | `value_class`, `generator_version` | `value_class` must equal `synthetic` |
| Participant separation | `actual_ficc_participant` | Must always be `false` |
| Treasury positions | Six maturity columns and total position | Buckets reconcile to total |
| Activity | `treasury_transaction_activity_usd` | Nonnegative USD value |
| Repo | Repo need and reverse-repo position | Nonnegative USD values |
| Settlement | Obligations, fails, and fail rate | Fails cannot exceed obligations |
| Collateral | Inventory and qualified resources | Resources cannot exceed inventory |
| Stress need | Stressed need and liquidity gap | Gap is derived and nonnegative |
| Concentration | `member_concentration_ratio` | Largest maturity share |
| Funding | Funding and net-repo dependency ratios | Bounded between zero and one |
| Coverage | Collateral and liquidity coverage ratios | Derived from stressed need |
| Risk | Score and risk band | Score is bounded from zero to 100 |

## Controlled artifacts

- Configuration: `configs/synthetic_members.yaml`
- Schema: `src/ficc_liquidity/synthetic/member_schema.py`
- Generator: `src/ficc_liquidity/synthetic/generate_members.py`
- Runtime Parquet: `data/synthetic/synthetic_members.parquet`
- Lineage manifest: `data/manifests/synthetic_member_manifest.csv`
- Machine-readable schema: `data/manifests/synthetic_member_schema.json`
- Tests: `tests/test_synthetic_member_schema.py`
- Evidence: `reports/evidence/section11_synthetic_member_schema.txt`

The runtime Parquet dataset remains excluded from Git because it is deterministically
reproducible. The configuration, code, tests, schema, manifest, and controlled evidence are
versioned.

## Limitations

The generator uses calibrated ranges and mathematical relationships rather than confidential
member records. It cannot reproduce actual member portfolios, intraday settlement queues,
bilateral credit terms, committed liquidity facilities, collateral eligibility decisions,
operational frictions, or FICC participant behavior. Results therefore support framework
development and model-validation demonstrations only.
