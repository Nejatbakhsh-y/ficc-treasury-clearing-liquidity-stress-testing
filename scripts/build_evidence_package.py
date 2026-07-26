"""Command-line wrapper for the Section 32 evidence-package builder."""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SRC_ROOT = REPO_ROOT / "src"
if str(SRC_ROOT) not in sys.path:
    sys.path.insert(0, str(SRC_ROOT))

from ficc_liquidity.reporting.evidence_package import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
