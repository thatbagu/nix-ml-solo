from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

import boto3
import typer
from botocore.exceptions import ClientError

sys.path.insert(0, str(Path(__file__).parent))
from _lib import (
    gum_confirm,
    project_root,
    region,
    require_ssh,
    tf_output,
)

app = typer.Typer(help="Package a trained model and deploy it for inference.")


def _serve_local(run_id: str, artifact_path: str) -> None:
    inference_port = os.environ.get("INFERENCE_PORT", "5001")
    typer.echo("▶ Serving model locally")
    typer.echo(f"  Run ID   : {run_id}")
    typer.echo(f"  Artifact : {artifact_path}")
    typer.echo(f"  Endpoint : http://localhost:{inference_port}/invocations")
    typer.echo("")
    typer.echo("  Test with:")
    typer.echo(f"    curl -X POST http://localhost:{inference_port}/invocations \\")
    typer.echo("      -H 'Content-Type: application/json' \\")
    typer.echo("      -d '{\"dataframe_split\": {\"columns\": [...], \"data\": [[...]]}}'")
    typer.echo("")
    typer.echo("  Ctrl-C to stop.")
    typer.echo("")

    subprocess.run(
        [
            "uv", "run", "mlflow", "models", "serve",
            "--model-uri", f"runs:/{run_id}/{artifact_path}",
            "--host", "127.0.0.1",
            "--port", inference_port,
            "--env-manager", "local",
        ],
        check=True,
    )


def _check_mlflow_health() -> bool:
    mlflow_port = os.environ.get("MLFLOW_PORT", "5000")
    result = subprocess.run(
        ["curl", "-sf", f"http://localhost:{mlflow_port}/health"],
        capture_output=True,
    )
    return result.returncode == 0


def _compute_build_tag() -> str:
    devenv_root = os.environ.get("DEVENV_ROOT", "")
    profile_path = Path(devenv_root) / ".devenv" / "profile"
    resolved = profile_path.resolve()
    profile_hash = resolved.name[:8]

    ep_path = project_root() / "infra" / "container" / "entrypoint.sh"
    ep_content = ep_path.read_bytes()
    ep_hash = hashlib.sha256(ep_content).hexdigest()[:8]

    return f"build-{profile_hash}-{ep_hash}"


def _check_ecr_image(ecr_repo: str, build_tag: str, aws_region: str) -> bool:
    ecr = boto3.client("ecr", region_name=aws_region)
    try:
        ecr.describe_images(
            repositoryName=ecr_repo,
            imageIds=[{"imageTag": build_tag}],
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] in ("ImageNotFoundException", "RepositoryNotFoundException"):
            return False
        raise


def _build_model_tarball(
    run_id: str,
    artifact_path: str,
    inference_script: str,
    tmp_dir: Path,
) -> Path:
    model_dir = tmp_dir / "model"
    model_dir.mkdir(parents=True, exist_ok=True)

    typer.echo("  Fetching artifacts from MLflow...")
    subprocess.run(
        [
            "uv", "run", "mlflow", "artifacts", "download",
            "--run-id", run_id,
            "--artifact-path", artifact_path,
            "--dst-path", str(model_dir),
        ],
        check=True,
    )

    code_dir = model_dir / "code"
    code_dir.mkdir(exist_ok=True)
    import shutil
    shutil.copy(inference_script, code_dir / "inference.py")

    devenv_root = os.environ.get("DEVENV_ROOT", str(project_root()))
    shutil.copy(Path(devenv_root) / "uv.lock", model_dir / "uv.lock")
    shutil.copy(Path(devenv_root) / "pyproject.toml", model_dir / "pyproject.toml")

    load_exports = Path(devenv_root) / ".devenv" / "load-exports"
    shutil.copy(load_exports, model_dir / "devenv-load.sh")

    typer.echo("  Assembling model.tar.gz...")
    tarball = tmp_dir / "model.tar.gz"
    with tarfile.open(tarball, "w:gz") as tf:
        tf.add(model_dir, arcname=".")
    return tarball


def _upload_to_s3(tarball: Path, dvc_bucket: str, run_id: str, aws_region: str) -> str:
    s3_key = f"model-artifacts/{run_id}/model.tar.gz"
    s3_uri = f"s3://{dvc_bucket}/{s3_key}"
    typer.echo(f"  Uploading to {s3_uri}...")
    subprocess.run(
        ["aws", "s3", "cp", str(tarball), s3_uri, "--region", aws_region],
        check=True,
    )
    return s3_uri


def _get_endpoint_status(endpoint_name: str, aws_region: str) -> str:
    sm = boto3.client("sagemaker", region_name=aws_region)
    try:
        resp = sm.describe_endpoint(EndpointName=endpoint_name)
        return resp["EndpointStatus"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "ValidationException":
            return "NotFound"
        raise


def _wait_endpoint_deleted(endpoint_name: str, aws_region: str) -> None:
    sm = boto3.client("sagemaker", region_name=aws_region)
    waiter = sm.get_waiter("endpoint_deleted")
    waiter.wait(EndpointName=endpoint_name)


def _wait_endpoint_in_service(endpoint_name: str, aws_region: str) -> None:
    sm = boto3.client("sagemaker", region_name=aws_region)
    waiter = sm.get_waiter("endpoint_in_service")
    waiter.wait(EndpointName=endpoint_name)


def _delete_endpoint(endpoint_name: str, aws_region: str) -> None:
    sm = boto3.client("sagemaker", region_name=aws_region)
    sm.delete_endpoint(EndpointName=endpoint_name)


def _remove_endpoint_from_tf_state(tf_dir: Path) -> None:
    subprocess.run(
        [
            "tofu", "state", "rm",
            "module.sagemaker[0].aws_sagemaker_endpoint.endpoint[0]",
        ],
        cwd=tf_dir,
        capture_output=True,
    )


def _handle_endpoint_state(endpoint_name: str, tf_dir: Path, aws_region: str) -> None:
    status = _get_endpoint_status(endpoint_name, aws_region)

    if status == "Failed":
        typer.echo(f"  Stale endpoint ({status}) — deleting...")
        _delete_endpoint(endpoint_name, aws_region)
        typer.echo("  Waiting for deletion...")
        _wait_endpoint_deleted(endpoint_name, aws_region)
        _remove_endpoint_from_tf_state(tf_dir)

    elif status == "NotFound":
        _remove_endpoint_from_tf_state(tf_dir)

    elif status == "InService":
        typer.echo(f"  Endpoint: {status}")

    elif status in ("Creating", "Updating", "SystemUpdating"):
        typer.echo(f"  Endpoint is {status} — waiting for terminal state before cleanup...")
        try:
            _wait_endpoint_in_service(endpoint_name, aws_region)
        except Exception:
            pass
        typer.echo("  Deleting stale endpoint...")
        try:
            _delete_endpoint(endpoint_name, aws_region)
        except ClientError:
            pass
        try:
            _wait_endpoint_deleted(endpoint_name, aws_region)
        except Exception:
            pass
        _remove_endpoint_from_tf_state(tf_dir)


def _deploy_cloud(run_id: str, artifact_path: str) -> None:
    inference_script = os.environ.get("INFERENCE_SCRIPT", "")
    if not inference_script:
        typer.echo("Error: INFERENCE_SCRIPT is not set.", err=True)
        typer.echo("  Set it in devenv.nix:  env.INFERENCE_SCRIPT = \"src/inference.py\";", err=True)
        typer.echo("  or export it:          export INFERENCE_SCRIPT=src/inference.py", err=True)
        raise typer.Exit(1)

    if not Path(inference_script).is_file():
        typer.echo(f"Error: inference script not found: {inference_script}", err=True)
        raise typer.Exit(1)

    require_ssh()

    if not _check_mlflow_health():
        typer.echo("[ deploy ] MLflow not reachable — connecting...")
        subprocess.run(["mlflow-open"], check=True)

    aws_region = region()
    tf_dir = project_root() / "infra" / "terraform"
    project = os.environ.get("TF_VAR_project", "ml-solo")
    env = os.environ.get("TF_VAR_environment", "dev")

    dvc_bucket = tf_output("dvc_bucket_name", tf_dir)
    ecr_uri = tf_output("ecr_repo_uri", tf_dir)

    build_tag = _compute_build_tag()
    ecr_repo = ecr_uri.split("/")[-1]

    if _check_ecr_image(ecr_repo, build_tag, aws_region):
        typer.echo(f"  Container image up to date ({build_tag})")
    else:
        typer.echo(f"  Container changed ({build_tag}) — rebuilding...")
        subprocess.run(["container-build"], check=True)

    model_s3_key = f"model-artifacts/{run_id}/model.tar.gz"
    model_s3_uri = f"s3://{dvc_bucket}/{model_s3_key}"

    typer.echo("▶ Packaging model for SageMaker")
    typer.echo(f"  Run ID            : {run_id}")
    typer.echo(f"  MLflow artifact   : {artifact_path}")
    typer.echo(f"  Inference script  : {inference_script}")
    typer.echo(f"  Destination       : {model_s3_uri}")
    typer.echo("")

    with tempfile.TemporaryDirectory() as tmp_str:
        tmp_dir = Path(tmp_str)
        tarball = _build_model_tarball(run_id, artifact_path, inference_script, tmp_dir)
        model_s3_uri = _upload_to_s3(tarball, dvc_bucket, run_id, aws_region)

    endpoint_name = f"{project}-{env}-endpoint"
    _handle_endpoint_state(endpoint_name, tf_dir, aws_region)

    typer.echo("")
    typer.echo("  Deploying SageMaker endpoint...")
    subprocess.run(["tofu", "init", "-upgrade=false"], cwd=tf_dir, check=True)
    subprocess.run(
        [
            "tofu", "apply", "-auto-approve",
            f"-var=sagemaker_model_image_uri={ecr_uri}:latest",
            f"-var=sagemaker_model_s3_uri={model_s3_uri}",
        ],
        cwd=tf_dir,
        check=True,
    )

    public_url_result = subprocess.run(
        ["tofu", "output", "-raw", "public_endpoint_url"],
        cwd=tf_dir,
        capture_output=True,
        text=True,
    )
    public_url = public_url_result.stdout.strip() if public_url_result.returncode == 0 else ""

    typer.echo("")
    typer.echo("  ─────────────────────────────────────────────────────")
    typer.echo(f"  Endpoint deployed: {endpoint_name}")
    typer.echo(f"  Run ID          : {run_id}")
    typer.echo("")
    typer.echo("  Private (AWS SDK / CLI):")
    typer.echo("    aws sagemaker-runtime invoke-endpoint \\")
    typer.echo(f"      --endpoint-name {endpoint_name} \\")
    typer.echo("      --content-type application/json \\")
    typer.echo("      --body fileb:///tmp/payload.json \\")
    typer.echo("      /tmp/out.json && cat /tmp/out.json")
    if public_url:
        typer.echo("")
        typer.echo("  Public (HTTP, no AWS auth):")
        typer.echo(f"    {public_url}")
        typer.echo("")
        typer.echo(f"    curl -X POST \"{public_url}\" \\")
        typer.echo("      -H \"Content-Type: application/json\" \\")
        typer.echo("      -d '{\"dataframe_split\": {\"columns\": [...], \"data\": [[...]]}}'")
    typer.echo("")
    typer.echo("  Status: deploy-status")
    typer.echo("  ─────────────────────────────────────────────────────")


@app.command()
def main(
    run_id: str = typer.Argument(..., help="MLflow run ID"),
    artifact_path: str = typer.Argument("model", help="MLflow artifact path (default: 'model')"),
) -> None:
    mode = os.environ.get("INFRA_MODE", "local")

    if mode == "local":
        _serve_local(run_id, artifact_path)
    elif mode == "cloud":
        _deploy_cloud(run_id, artifact_path)
    else:
        typer.echo(f"Unknown INFRA_MODE '{mode}'. Set to 'local' or 'cloud'.", err=True)
        raise typer.Exit(1)


app()
