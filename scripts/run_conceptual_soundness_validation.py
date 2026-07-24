"""Run Section 24 conceptual-soundness validation."""

from __future__ import annotations

import argparse
from pathlib import Path

from ficc_liquidity.validation.conceptual_soundness import (
    ConceptualSoundnessValidator,
    load_validation_config,
    write_outputs,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--project-root",
        type=Path,
        default=Path.cwd(),
        help="Repository root.",
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=Path("configs/conceptual_soundness_validation.yaml"),
        help="Section 24 validation configuration.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project_root = args.project_root.resolve()
    config_path = args.config
    if not config_path.is_absolute():
        config_path = project_root / config_path

    config = load_validation_config(config_path)
    validator = ConceptualSoundnessValidator(project_root, config)
    summary = validator.run()
    outputs = write_outputs(summary, project_root, config["outputs"])

    print("Section 24 conceptual soundness validation")
    print(f"Overall status: {summary['overall_status']}")
    print(f"Weighted score: {float(summary['weighted_score']):.2%}")
    print(f"Critical failures: {len(summary['critical_failures'])}")
    for name, path in sorted(outputs.items()):
        print(f"{name}: {path.relative_to(project_root)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
