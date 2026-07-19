# Model Inventory

## Inventory purpose

This inventory identifies the analytical components planned for the public-data FICC GSD liquidity stress framework. IDs remain stable across code, configuration, tests, evidence, findings, and reports.

| Model ID | Component | Purpose | Primary inputs | Primary outputs | Value class | Materiality | Validation status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LST-001 | Market Data Ingestion and Harmonization | Acquire and align authoritative public Treasury and repo series | NY Fed, Federal Reserve, DTCC, SEC, U.S. Treasury data | Versioned analytical time series | Observed and derived | High | Planned |
| LST-002 | Market Stress Feature Engine | Convert public observations into standardized liquidity-stress indicators | Harmonized time series | Changes, volatilities, percentiles, event shocks | Derived | High | Planned |
| LST-003 | Synthetic Member-Family Allocator | Allocate aggregate activity to anonymous member families | Aggregate activity, seed, concentration assumptions | Synthetic family exposures | Synthetic and assumed | Critical | Planned |
| LST-004 | Baseline Liquidity-Need Model | Estimate net settlement liquidity need by synthetic family | Synthetic exposures, settlement assumptions, market features | Baseline net liquidity requirement | Modeled | Critical | Planned |
| LST-005 | Historical Stress Engine | Replay public historical shocks through the proxy portfolio | Historical event shocks, baseline requirements | Historically stressed requirements | Derived and modeled | Critical | Planned |
| LST-006 | Hypothetical Stress Engine | Apply configuration-controlled extreme but plausible shocks | Scenario assumptions, baseline requirements | Hypothetically stressed requirements | Assumed and modeled | Critical | Planned |
| LST-007 | Qualifying Liquid Resources Proxy | Estimate resources available within each scenario and horizon | Public disclosures, eligibility and availability assumptions | Available-resource proxy | Observed, assumed, synthetic, and modeled | Critical | Planned |
| LST-008 | Cover One Aggregator | Select the largest positive synthetic member-family requirement | Family-level stressed requirements | Cover One requirement | Modeled | Critical | Planned |
| LST-009 | Cover Two Challenger | Sum the two largest positive synthetic family requirements | Family-level stressed requirements | Cover Two challenger requirement | Modeled | High | Planned |
| LST-010 | Coverage and Shortfall Calculator | Compare available resources with stressed requirements | Resource proxy, Cover One or Cover Two requirement | LCR, shortfall, breach flag | Modeled | Critical | Planned |
| LST-011 | Sensitivity and Uncertainty Engine | Quantify dependence on material assumptions | Parameter grids, alternative seeds and models | Sensitivity surfaces and uncertainty ranges | Modeled | High | Planned |
| LST-012 | Monitoring and Validation Reporting | Produce traceable diagnostics and decision-use controls | Model outputs, test results, findings | Reports, evidence, dashboards | Derived and modeled | High | Planned |

## Critical-model conventions

- Critical components require independent formula reconciliation and documented test evidence.
- LST-003 outputs never use actual firm names or imply that allocation weights are observed.
- LST-007 reports observed resource disclosures separately from assumed availability and timing adjustments.
- LST-009 is a project challenger and is not labeled as FICC's disclosed minimum requirement.
- All model outputs include `model_id`, `model_version`, `run_id`, `scenario_id`, `as_of_date`, and `value_type`.

## Ownership and review cycle

| Role | Assigned party | Responsibility |
| --- | --- | --- |
| Project and model owner | Yousef Nejatbakhsh | Requirements, implementation, documentation, remediation |
| Independent validation function | Independent validation workstream | Challenge, testing, findings, approval recommendation |
| Data owner | Public-data pipeline workstream | Source control, lineage, quality, definitions, revisions |
| Model-risk approver | Project governance role | Scope and final-use approval based on evidence |

Inventory review occurs at each phase gate and whenever a component, material assumption, data source, intended use, or critical output changes. The initial inventory was approved for implementation on 2026-07-19 with scope status **APPROVED**.
