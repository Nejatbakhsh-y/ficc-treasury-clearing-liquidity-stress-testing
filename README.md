# FICC Treasury Clearing Liquidity Stress Testing and Model Validation

[![CI](https://github.com/Nejatbakhsh-y/ficc-treasury-clearing-liquidity-stress-testing/actions/workflows/ci.yml/badge.svg)](https://github.com/Nejatbakhsh-y/ficc-treasury-clearing-liquidity-stress-testing/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An independent, reproducible framework for studying FICC-style Treasury-clearing liquidity stress using public aggregate data. The project covers liquidity-resource and liquidity-obligation proxies, Cover 1 and Cover 2 scenarios, historical and hypothetical stresses, Liquidity Coverage Ratio analysis, sensitivity testing, performance monitoring, and model validation.

## Intended use

This repository is a research and model-validation project. It is not an implementation of DTCC or FICC production models and must not be used for live clearing, funding, investment, regulatory reporting, or risk-limit decisions.

## Data classification

Every material field and result must be classified as **observed**, **derived**, **synthetic**, **assumed**, or **modeled**. Public aggregate Federal Reserve and other authoritative data cannot identify confidential FICC member positions, settlement obligations, committed facilities, or proprietary stress methodology.

## Initial structure

| Path | Purpose |
|---|---|
| .github/ | CI, dependency management, ownership, and collaboration templates |
| configs/ | Version-controlled model and scenario configurations |
| data/ | Data documentation and local pipeline outputs |
| docs/ | Charters, methodology, governance, limitations, and decisions |
|
otebooks/ | Controlled exploratory analysis |
|
eports/ | Generated tables, figures, evidence, and validation reports |
| scripts/ | Reproducible command-line entry points and automation |
| sql/ | Data controls, transformations, and analytical queries |
| src/ficc_liquidity/ | Production-quality Python package |
| 	ests/ | Unit, integration, data-quality, and model-validation tests |

## Development

`powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install --upgrade pip
python -m pip install -e ".[dev]"
ruff check .
ruff format --check .
pytest
`

See [CONTRIBUTING.md](CONTRIBUTING.md), [SECURITY.md](SECURITY.md), and [docs/project_backlog.md](docs/project_backlog.md).

<!-- BEGIN SECTION 33 DASHBOARD -->

## Streamlit Dashboard

Phase IX, Section 33 provides a controlled multipage Streamlit dashboard for:

- public Federal Reserve market conditions;
- synthetic clearing-member exposures;
- Cover 1 and Cover 2 results;
- historical and hypothetical stress scenarios;
- Liquidity Coverage Ratio and shortfalls;
- component contributions;
- sensitivity and reverse-stress testing;
- monthly monitoring;
- findings, remediation, limitations, and governance.

Run locally:

Run .\.venv\Scripts\python.exe -m streamlit run dashboard\streamlit_app.py from the repository root.

All participant-level views use fictional synthetic members. The dashboard does not
display, identify, or infer actual FICC or DTCC participant-level information.

<!-- END SECTION 33 DASHBOARD -->

<!-- SECTION34:START -->
## Phase IX - Section 34: Independent Validation Report

The controlled final validation package is available at:

- [Independent validation report](reports/independent_validation_report.md)
- [Evidence index](reports/validation/section34_evidence_index.md)
- [Report readiness](reports/validation/section34_report_readiness.csv)
- [Completion checklist](reports/validation/section34_completion_checklist.md)
- [Report manifest](reports/validation/section34_report_manifest.json)

Automated conclusion: **CONDITIONALLY SATISFACTORY**
<!-- SECTION34:END -->

<!-- BEGIN SECTION 35 INSTALLATION -->
## Installation and fresh-clone reproduction

The controlled development environment uses Python 3.11. From Windows PowerShell in a fresh clone:

```powershell
git clone https://github.com/nejatbakhsh-y/ficc-treasury-clearing-liquidity-stress-testing.git
Set-Location ficc-treasury-clearing-liquidity-stress-testing
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install --upgrade pip
.\.venv\Scripts\python.exe -m pip install -e ".[dev]"
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe -m ruff check .
.\.venv\Scripts\python.exe -m mypy src tests
```

Repository data controls prohibit raw, confidential, participant-level, and runtime-generated datasets from being committed. The public analytical package uses official public data, documented transformations, and synthetic clearing-member representations only.
<!-- END SECTION 35 INSTALLATION -->
