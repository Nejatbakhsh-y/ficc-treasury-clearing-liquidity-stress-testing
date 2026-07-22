"""Run the Phase V Section 14 baseline liquidity cash-flow engine."""

from __future__ import annotations

import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[1]
SRC_ROOT = PROJECT_ROOT / "src"
if str(SRC_ROOT) not in sys.path:
    sys.path.insert(0, str(SRC_ROOT))

from ficc_liquidity.liquidity.baseline_cashflow import main  # noqa: E402, I001


if __name__ == "__main__":
    raise SystemExit(main())
