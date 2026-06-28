from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def project_root() -> Path:
    return Path(os.environ["PROJECT_ROOT"])


def require_cloud() -> None:
    if os.environ.get("INFRA_MODE", "local") != "cloud":
        print("Error: this command requires cloud mode (INFRA_MODE=cloud).", file=sys.stderr)
        sys.exit(1)


def require_ssh() -> None:
    ssh_id = os.environ.get("SSH_IDENTITY_FILE", "")
    if not ssh_id or not Path(ssh_id).is_file():
        print("Error: SSH_IDENTITY_FILE not set or missing. Run 'setup'.", file=sys.stderr)
        sys.exit(1)


def tf_output(key: str, tf_dir: Path) -> str:
    result = subprocess.run(
        ["tofu", "output", "-raw", key],
        cwd=tf_dir,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        print(f"Error: tofu output {key} failed: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def tf_output_optional(key: str, tf_dir: Path) -> str:
    result = subprocess.run(
        ["tofu", "output", "-raw", key],
        cwd=tf_dir,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def gum_confirm(msg: str, default: bool = False) -> bool:
    args = ["gum", "confirm", msg]
    args.append("--default=true" if default else "--default=false")
    result = subprocess.run(args)
    return result.returncode == 0


def gum_choose(header: str, options: list[str]) -> str:
    result = subprocess.run(
        ["gum", "choose", "--header", header, *options],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0 or not result.stdout.strip():
        print("Aborted.", file=sys.stderr)
        sys.exit(0)
    return result.stdout.strip()


def region() -> str:
    return os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
