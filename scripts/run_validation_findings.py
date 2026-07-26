"""Command-line runner for the Section 31 validation finding register."""

from __future__ import annotations

import argparse
import json
from datetime import date
from pathlib import Path

from ficc_liquidity.governance.validation_findings import (
    ValidationFindingRegister,
    build_demo_rows,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/validation_findings.yaml"),
    )
    parser.add_argument(
        "--input",
        type=Path,
        default=Path("data/manifests/validation_finding_register.csv"),
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("reports/governance/findings/latest"),
    )
    parser.add_argument(
        "--as-of-date",
        default=date.today().isoformat(),
    )
    parser.add_argument(
        "--demo",
        action="store_true",
        help="Use the deterministic synthetic demonstration findings.",
    )
    parser.add_argument(
        "--validate-only",
        action="store_true",
        help="Validate without writing report outputs.",
    )
    parser.add_argument(
        "--next-id-year",
        type=int,
        help="Print the next finding ID for this year and exit after validation.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    controller = ValidationFindingRegister.from_yaml(args.config)
    rows = build_demo_rows() if args.demo else controller.load_csv(args.input)
    issues = controller.validate(
        rows,
        as_of_date=args.as_of_date,
        raise_on_error=True,
    )
    summary = controller.summarize(
        rows,
        as_of_date=args.as_of_date,
        issues=issues,
    )

    payload: dict[str, object] = {
        "summary": summary.__dict__,
        "issues": [issue.__dict__ for issue in issues],
    }

    if args.next_id_year is not None:
        payload["next_finding_id"] = controller.next_finding_id(
            rows,
            year=args.next_id_year,
        )

    if not args.validate_only:
        outputs = controller.write_outputs(
            rows,
            output_dir=args.output_dir,
            as_of_date=args.as_of_date,
            issues=issues,
        )
        payload["outputs"] = {name: str(path) for name, path in outputs.items()}

    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
