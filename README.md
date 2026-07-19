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
| eports/ | Generated tables, figures, evidence, and validation reports |
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
