from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import typer

sys.path.insert(0, str(Path(__file__).parent))
from _lib import (
    gum_choose,
    gum_confirm,
    project_root,
    require_cloud,
    require_ssh,
    tf_output,
)

app = typer.Typer(help="Restore MLflow data and DVC after a fresh setup.")


@app.command()
def main() -> None:
    require_cloud()
    require_ssh()

    backups_dir = project_root() / "backups"
    tf_dir = project_root() / "infra" / "terraform"

    if not backups_dir.is_dir() or not any(backups_dir.iterdir()):
        typer.echo(f"No backups found in {backups_dir}")
        raise typer.Exit(0)

    # List backups newest-first by mtime
    backup_entries = sorted(
        (p for p in backups_dir.iterdir() if p.is_dir()),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    backup_names = [p.name for p in backup_entries]

    selected = gum_choose("Select backup to restore:", backup_names)

    backup_dir = backups_dir / selected
    meta_path = backup_dir / "meta.json"

    typer.echo("")
    typer.echo(f"  Backup: {selected}")

    dvc_pulled = False
    if meta_path.is_file():
        try:
            meta = json.loads(meta_path.read_text())
            timestamp = meta.get("timestamp", "unknown")
            git_commit = meta.get("git_commit", "unknown")
            dvc_pulled = meta.get("dvc_pulled", False)
            typer.echo(f"  Date      : {timestamp}")
            typer.echo(f"  Git commit: {git_commit}")
            typer.echo(f"  DVC pulled: {dvc_pulled}")
        except (json.JSONDecodeError, OSError):
            pass

    ec2_ip = tf_output("ec2_public_ip", tf_dir)
    ssh_id = os.environ.get("SSH_IDENTITY_FILE", "")

    ssh_cmd = [
        "ssh",
        "-i", ssh_id,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        f"ml@{ec2_ip}",
    ]

    # Restore MLflow
    mlflow_backup = backup_dir / "mlflow"
    if mlflow_backup.is_dir() and any(mlflow_backup.iterdir()):
        typer.echo("")
        if gum_confirm("  Restore MLflow experiments to EC2?", default=True):
            typer.echo(f"  Pushing MLflow data → ml@{ec2_ip}...")

            tar_proc = subprocess.Popen(
                ["tar", "czf", "-", "-C", str(mlflow_backup), "."],
                stdout=subprocess.PIPE,
            )
            ssh_proc = subprocess.Popen(
                [*ssh_cmd, "tar xzf - -C /home/ml/"],
                stdin=tar_proc.stdout,
            )
            if tar_proc.stdout:
                tar_proc.stdout.close()
            ssh_proc.wait()
            tar_proc.wait()
            typer.echo("  MLflow experiments restored.")
    else:
        typer.echo("  No MLflow backup found in this snapshot.")

    # Restore DVC
    if dvc_pulled:
        typer.echo("")
        if gum_confirm("  Push local DVC data back to S3?", default=True):
            typer.echo("  Pushing DVC data → S3...")
            subprocess.run(["uv", "run", "dvc", "push"], cwd=project_root(), check=True)
            typer.echo("  DVC data pushed.")

    typer.echo("")
    typer.echo("  ─────────────────────────────────────────────────────────")
    typer.echo("  Restore complete.")
    typer.echo("  ─────────────────────────────────────────────────────────")


app()
