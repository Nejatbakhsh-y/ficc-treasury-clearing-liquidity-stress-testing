from pathlib import Path

import ficc_liquidity


def test_package_version_is_defined() -> None:
    assert ficc_liquidity.__version__ == "0.1.0"


def test_required_repository_files_exist() -> None:
    root = Path(__file__).resolve().parents[1]
    required = [
        "README.md",
        "LICENSE",
        "SECURITY.md",
        "CONTRIBUTING.md",
        "CITATION.cff",
        "pyproject.toml",
        ".github/CODEOWNERS",
        ".github/dependabot.yml",
        ".github/workflows/ci.yml",
    ]
    assert all((root / path).is_file() for path in required)
