"""Launch the Phase IX, Section 33 Streamlit dashboard."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8501)
    parser.add_argument("--headless", action="store_true")
    parser.add_argument(
        "--no-demo",
        action="store_true",
        help="Fail when repository evidence is absent instead of using synthetic fallback data.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = Path(__file__).resolve().parents[1]
    app = root / "dashboard" / "streamlit_app.py"
    environment = dict(os.environ)
    environment["FICC_DASHBOARD_ALLOW_DEMO"] = "0" if args.no_demo else "1"

    command = [
        sys.executable,
        "-m",
        "streamlit",
        "run",
        str(app),
        f"--server.port={args.port}",
        f"--server.headless={'true' if args.headless else 'false'}",
        "--browser.gatherUsageStats=false",
    ]
    return subprocess.call(command, cwd=root, env=environment)


if __name__ == "__main__":
    raise SystemExit(main())
