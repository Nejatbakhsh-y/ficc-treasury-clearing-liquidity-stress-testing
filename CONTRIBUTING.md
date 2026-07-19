# Contributing

Thank you for contributing to this research and model-validation project.

## Development workflow

1. Create or select a documented GitHub issue.
2. Create a focused branch from `main` using `feature/`, `fix/`, `data/`, or `docs/`.
3. Keep assumptions, configuration changes, and data lineage explicit.
4. Add or update tests for every behavior change.
5. Run `ruff check .`, `ruff format --check .`, and `pytest` locally.
6. Open a pull request and complete every applicable checklist item.
7. Merge only after required checks pass and conversations are resolved.

## Model-risk requirements

- State the intended use, theoretical basis, material assumptions, limitations, and failure modes.
- Distinguish observed, derived, synthetic, assumed, and modeled values.
- Assess sensitivity, benchmark performance, implementation correctness, and outcome stability.
- Do not present public-data proxies as confidential FICC exposures or resources.
- Record findings with severity, evidence, owner, remediation, and target date.

## Data-quality requirements

- Use authoritative sources where available and retain source URLs and retrieval timestamps.
- Validate schema, type, uniqueness, completeness, timeliness, ranges, and reconciliation.
- Never commit secrets, credentials, restricted data, raw personal data, or large generated outputs.
- Document transformations and preserve reproducible manifests or checksums where appropriate.

## Commit and pull-request scope

Use concise imperative commit messages. Keep pull requests reviewable and do not combine unrelated model, data, documentation, and infrastructure changes.
