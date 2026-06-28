from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

import boto3
import typer
from botocore.exceptions import ClientError

sys.path.insert(0, str(Path(__file__).parent))
from _lib import (
    gum_confirm,
    project_root,
    region,
    require_cloud,
    tf_output_optional,
)

app = typer.Typer(help="Tear down all cloud infrastructure.")


def _check_aws_creds() -> None:
    result = subprocess.run(
        ["aws", "sts", "get-caller-identity"],
        capture_output=True,
    )
    if result.returncode != 0:
        typer.echo("", err=True)
        typer.echo("  Error: AWS credentials are invalid or expired.", err=True)
        typer.echo("  Run 'setup' to generate fresh credentials, then re-run teardown.", err=True)
        typer.echo("", err=True)
        raise typer.Exit(1)


def _s3_size(bucket: str, aws_region: str) -> str:
    result = subprocess.run(
        [
            "aws", "s3", "ls", f"s3://{bucket}",
            "--recursive", "--human-readable", "--summarize",
            "--region", aws_region,
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return "unknown"
    for line in result.stdout.splitlines():
        if "Total Size" in line:
            return line.split("Total Size:")[-1].strip()
    return "unknown"


def _backup_mlflow(ec2_ip: str, ssh_id: str, backup_dir: Path) -> None:
    typer.echo("  Backing up MLflow data from EC2...")
    mlflow_dir = backup_dir / "mlflow"
    mlflow_dir.mkdir(parents=True, exist_ok=True)

    ssh_cmd = [
        "ssh", "-i", ssh_id,
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        f"ml@{ec2_ip}",
        "tar czf - -C /home/ml mlflow.db mlflow.db-shm mlflow.db-wal 2>/dev/null",
    ]
    tar_cmd = ["tar", "xzf", "-", "-C", str(mlflow_dir)]

    ssh_proc = subprocess.Popen(ssh_cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    tar_proc = subprocess.Popen(tar_cmd, stdin=ssh_proc.stdout, stderr=subprocess.DEVNULL)
    if ssh_proc.stdout:
        ssh_proc.stdout.close()
    tar_proc.wait()
    ssh_proc.wait()

    size_result = subprocess.run(
        ["du", "-sh", str(mlflow_dir)],
        capture_output=True, text=True,
    )
    size = size_result.stdout.split("\t")[0] if size_result.returncode == 0 else "0"
    typer.echo(f"  MLflow backed up → {mlflow_dir}  ({size})")


def _save_meta(
    backup_dir: Path,
    dvc_bucket: str,
    ec2_ip: str,
    dvc_pulled: bool,
) -> None:
    backup_dir.mkdir(parents=True, exist_ok=True)
    git_result = subprocess.run(
        ["git", "-C", str(project_root()), "rev-parse", "--short", "HEAD"],
        capture_output=True, text=True,
    )
    git_commit = git_result.stdout.strip() if git_result.returncode == 0 else "unknown"

    meta = {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "dvc_bucket": dvc_bucket,
        "ec2_ip": ec2_ip,
        "dvc_pulled": dvc_pulled,
        "git_commit": git_commit,
    }
    (backup_dir / "meta.json").write_text(json.dumps(meta, indent=2))


def _stop_background_processes(project: str) -> None:
    typer.echo("  Stopping file sync...")
    subprocess.run(["mutagen", "sync", "terminate", project], capture_output=True)

    typer.echo("  Closing SSH tunnels...")
    mlflow_port = os.environ.get("MLFLOW_PORT", "5000")
    jupyter_port = os.environ.get("JUPYTER_PORT", "8888")
    subprocess.run(
        ["pkill", "-f", f"ssh.*{mlflow_port}:localhost:{mlflow_port}"],
        capture_output=True,
    )
    subprocess.run(
        ["pkill", "-f", f"ssh.*{jupyter_port}:localhost:{jupyter_port}"],
        capture_output=True,
    )


def _get_sg_id(project: str, env: str, aws_region: str) -> str:
    ec2 = boto3.client("ec2", region_name=aws_region)
    try:
        resp = ec2.describe_security_groups(
            Filters=[{"Name": "group-name", "Values": [f"{project}-{env}-sagemaker-sg"]}]
        )
        groups = resp.get("SecurityGroups", [])
        return groups[0]["GroupId"] if groups else ""
    except ClientError:
        return ""


def _pre_destroy_sagemaker(tf_dir: Path) -> None:
    typer.echo("  [1/3] removing SageMaker endpoint...")
    subprocess.run(
        [
            "tofu", "destroy", "-auto-approve",
            "-target", "module.sagemaker[0].aws_sagemaker_endpoint.endpoint[0]",
            "-target", "module.sagemaker[0].aws_sagemaker_endpoint_configuration.config[0]",
            "-target", "module.sagemaker[0].aws_sagemaker_model.model[0]",
        ],
        cwd=tf_dir,
        capture_output=True,
    )


def _pre_destroy_vpc_endpoints(tf_dir: Path) -> None:
    typer.echo("  [2/3] removing VPC interface endpoints...")
    subprocess.run(
        [
            "tofu", "destroy", "-auto-approve",
            "-target", "module.ec2[0].aws_vpc_endpoint.ecr_api",
            "-target", "module.ec2[0].aws_vpc_endpoint.ecr_dkr",
        ],
        cwd=tf_dir,
        capture_output=True,
    )


def _poll_and_clear_enis(sg_id: str, aws_region: str) -> None:
    typer.echo(f"  [3/3] clearing ENIs from {sg_id}...")
    ec2 = boto3.client("ec2", region_name=aws_region)
    for i in range(1, 25):
        try:
            resp = ec2.describe_network_interfaces(
                Filters=[{"Name": "group-id", "Values": [sg_id]}]
            )
        except ClientError:
            break
        enis = resp.get("NetworkInterfaces", [])
        if not enis:
            typer.echo("  ENIs cleared.")
            break

        for eni in enis:
            if eni.get("Status") == "available":
                eni_id = eni["NetworkInterfaceId"]
                typer.echo(f"  Deleting orphaned ENI {eni_id}...")
                try:
                    ec2.delete_network_interface(NetworkInterfaceId=eni_id)
                except ClientError:
                    pass

        print(f"  {len(enis)} ENI(s) in-use — waiting for AWS cleanup ({i}/24)…", end="\r", flush=True)
        time.sleep(15)


def _drain_ecr(project: str, env: str, aws_region: str) -> None:
    ecr_repo = f"{project}-{env}-ml"
    ecr = boto3.client("ecr", region_name=aws_region)
    try:
        resp = ecr.list_images(repositoryName=ecr_repo)
        image_ids = resp.get("imageIds", [])
    except ClientError:
        return
    if image_ids:
        typer.echo(f"  [4/4] draining ECR repo {ecr_repo}...")
        try:
            ecr.batch_delete_image(repositoryName=ecr_repo, imageIds=image_ids)
        except ClientError as e:
            typer.echo(f"  Warning: ECR drain failed: {e}", err=True)


def _run_tofu_destroy(tf_dir: Path) -> None:
    typer.echo("  Destroying terraform-managed resources...")
    subprocess.run(["tofu", "destroy", "-auto-approve"], cwd=tf_dir)


def _run_aws_nuke(project: str, aws_region: str) -> None:
    sts = boto3.client("sts", region_name=aws_region)
    try:
        identity = sts.get_caller_identity()
    except ClientError:
        return
    account_id = identity.get("Account", "")
    caller_arn = identity.get("Arn", "")
    if not account_id:
        return

    typer.echo("")
    typer.echo("  Running aws-nuke sweep...")

    iam = boto3.client("iam", region_name=aws_region)
    try:
        iam.create_account_alias(AccountAlias=project)
    except ClientError:
        pass

    caller_user = caller_arn.split("/")[-1] if "/" in caller_arn else ""

    nuke_yaml = f"""regions:
  - {aws_region}
  - global

blocklist:
  - "000000000000"

accounts:
  "{account_id}":
    filters:
      IAMUser:
        - "root"
        - "{caller_user}"
      IAMUserAccessKey:
        - type: "regex"
          value: "^{caller_user} -> .*"
      IAMUserPolicyAttachment:
        - type: "regex"
          value: "^{caller_user} -> .*"
"""

    with tempfile.NamedTemporaryFile(mode="w", suffix=".yaml", delete=False) as f:
        f.write(nuke_yaml)
        nuke_config = f.name

    try:
        result = subprocess.run(
            [
                "aws-nuke", "run",
                "--config", nuke_config,
                "--no-dry-run",
                "--force",
            ],
            capture_output=True,
            text=True,
        )
        filtered = "\n".join(
            line for line in result.stdout.splitlines()
            if not line.startswith(("Scan", "aws-nuke version", "No resource", "time="))
        )
        if filtered:
            typer.echo(filtered)
    finally:
        Path(nuke_config).unlink(missing_ok=True)


def _delete_deploy_user(project: str, aws_region: str) -> None:
    deploy_user = f"{project}-deploy"
    iam = boto3.client("iam", region_name=aws_region)

    try:
        iam.get_user(UserName=deploy_user)
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchEntity":
            return
        raise

    typer.echo(f"  Deleting IAM user {deploy_user}...")

    try:
        resp = iam.list_attached_user_policies(UserName=deploy_user)
        for policy in resp.get("AttachedPolicies", []):
            try:
                iam.detach_user_policy(UserName=deploy_user, PolicyArn=policy["PolicyArn"])
            except ClientError:
                pass
    except ClientError:
        pass

    try:
        resp = iam.list_access_keys(UserName=deploy_user)
        for key in resp.get("AccessKeyMetadata", []):
            try:
                iam.delete_access_key(UserName=deploy_user, AccessKeyId=key["AccessKeyId"])
            except ClientError:
                pass
    except ClientError:
        pass

    try:
        iam.delete_user(UserName=deploy_user)
        typer.echo(f"  IAM user {deploy_user} deleted.")
    except ClientError as e:
        typer.echo(f"  Warning: could not delete IAM user {deploy_user}: {e}", err=True)


@app.command()
def main() -> None:
    require_cloud()
    _check_aws_creds()

    tf_dir = project_root() / "infra" / "terraform"
    aws_region = region()
    timestamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
    backup_dir = project_root() / "backups" / timestamp

    dvc_bucket = tf_output_optional("dvc_bucket_name", tf_dir)
    ec2_ip = tf_output_optional("ec2_public_ip", tf_dir)

    typer.echo("")
    typer.echo("  ─────────────────────────────────────────────────────────")
    typer.echo("  teardown — destroys ALL cloud infrastructure")
    typer.echo("  ─────────────────────────────────────────────────────────")
    typer.echo("")

    if dvc_bucket:
        typer.echo("  Calculating S3 storage sizes...")
        dvc_size = _s3_size(dvc_bucket, aws_region)
    else:
        dvc_size = "unknown (state already destroyed)"

    typer.echo("")
    typer.echo(f"  DVC data (s3://{dvc_bucket or '<unknown>'}): {dvc_size}")
    typer.echo("  Nix cache: regenerable — skipping")
    typer.echo("")

    # Backup MLflow from EC2
    dvc_pulled = False
    ssh_id = os.environ.get("SSH_IDENTITY_FILE", "")
    if ec2_ip and ssh_id and Path(ssh_id).is_file():
        _backup_mlflow(ec2_ip, ssh_id, backup_dir)
    else:
        typer.echo("  Skipping MLflow backup (EC2 not reachable).")

    # Offer DVC pull
    typer.echo("")
    if gum_confirm(f"  Download DVC data locally before destroying? ({dvc_size})", default=False):
        typer.echo("")
        typer.echo(f"  Pulling DVC data → {project_root()} ...")
        subprocess.run(["uv", "run", "dvc", "pull"], cwd=project_root(), check=True)
        dvc_pulled = True
        typer.echo("  DVC data saved locally.")

    # Save backup metadata
    _save_meta(backup_dir, dvc_bucket, ec2_ip, dvc_pulled)

    typer.echo("")
    typer.echo(f"  Backup saved → {backup_dir}")
    typer.echo("  Run 'restore' after your next setup to recover MLflow experiments")
    if dvc_pulled:
        typer.echo("  and push DVC data back with 'dvc push'.")

    # Final confirmation
    typer.echo("")
    subprocess.run(
        [
            "gum", "style",
            "--border", "double",
            "--border-foreground", "196",
            "--padding", "1 4",
            "  WARNING: this will destroy EC2, SageMaker, ECR, S3, and all related resources.  ",
        ]
    )
    typer.echo("")

    if not gum_confirm("  Confirm: destroy everything?", default=False):
        typer.echo("Aborted.")
        raise typer.Exit(0)

    project = os.environ.get("TF_VAR_project", "nix-ml-solo")
    env = os.environ.get("TF_VAR_environment", "dev")

    # Stop background processes
    typer.echo("")
    _stop_background_processes(project)

    # Destroy infrastructure
    typer.echo("")
    typer.echo("  Destroying infrastructure...")

    sg_id = _get_sg_id(project, env, aws_region)

    _pre_destroy_sagemaker(tf_dir)
    _pre_destroy_vpc_endpoints(tf_dir)

    if sg_id and sg_id != "None":
        _poll_and_clear_enis(sg_id, aws_region)

    _drain_ecr(project, env, aws_region)
    _run_tofu_destroy(tf_dir)
    _run_aws_nuke(project, aws_region)
    _delete_deploy_user(project, aws_region)

    typer.echo("")
    typer.echo("  ─────────────────────────────────────────────────────────")
    typer.echo("  Done. Cloud infrastructure destroyed.")
    typer.echo(f"  Backup: {backup_dir}")
    typer.echo("  Run 'setup' to provision again, then 'restore' to recover data.")
    typer.echo("  Note: re-run 'tf-bootstrap' before 'tf-apply' (state bucket was nuked).")
    typer.echo("  ─────────────────────────────────────────────────────────")


app()
