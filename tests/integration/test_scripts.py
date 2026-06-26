"""Shell script guard and config-generation tests.

These run bash subprocesses — no AWS credentials or cloud infra needed.
"""

import glob
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.parent
LIB = ROOT / "infra" / "scripts" / "_lib.sh"


def bash(script: str, env: dict | None = None) -> subprocess.CompletedProcess:
    merged = {**os.environ, **(env or {})}
    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        env=merged,
        cwd=ROOT,
    )


class TestRequireCloud:
    def test_fails_in_local_mode(self):
        result = bash(
            f"source '{LIB}' && _require_cloud",
            env={"INFRA_MODE": "local"},
        )
        assert result.returncode != 0
        assert "cloud mode" in result.stderr

    def test_passes_in_cloud_mode(self):
        result = bash(
            f"source '{LIB}' && _require_cloud",
            env={"INFRA_MODE": "cloud"},
        )
        assert result.returncode == 0

    def test_fails_when_mode_unset(self):
        env = {k: v for k, v in os.environ.items() if k != "INFRA_MODE"}
        result = bash(f"source '{LIB}' && _require_cloud", env=env)
        assert result.returncode != 0


class TestRequireSsh:
    def test_fails_when_file_missing(self, tmp_path):
        result = bash(
            f"source '{LIB}' && _require_ssh",
            env={
                "INFRA_MODE": "cloud",
                "SSH_IDENTITY_FILE": str(tmp_path / "nonexistent_key"),
            },
        )
        assert result.returncode != 0
        assert "SSH_IDENTITY_FILE" in result.stderr

    def test_fails_when_var_unset(self):
        env = {k: v for k, v in os.environ.items() if k != "SSH_IDENTITY_FILE"}
        result = bash(f"source '{LIB}' && _require_ssh", env=env)
        assert result.returncode != 0

    def test_passes_when_key_exists(self, tmp_path):
        key = tmp_path / "id_ed25519"
        key.touch()
        result = bash(
            f"source '{LIB}' && _require_ssh",
            env={"SSH_IDENTITY_FILE": str(key)},
        )
        assert result.returncode == 0


class TestTrainGuards:
    TRAIN = ROOT / "infra" / "scripts" / "training" / "train.sh"

    def test_no_arg_exits_nonzero(self):
        result = bash(
            f"bash '{self.TRAIN}'",
            env={"INFRA_MODE": "local", "TRAINING_SCRIPT": ""},
        )
        assert result.returncode != 0
        assert "Usage:" in result.stderr

    def test_training_script_env_satisfies_guard(self):
        result = bash(
            f"bash '{self.TRAIN}'",
            env={
                "INFRA_MODE": "local",
                "TRAINING_SCRIPT": "src/train.py",
                "MLFLOW_TRACKING_URI": "http://localhost:19999",
                "DVC_REMOTE_URL": "s3://test-bucket/dvc",
            },
        )
        assert "Usage:" not in result.stderr
        assert "MLflow is not running" in result.stderr

    def test_unknown_infra_mode_exits_nonzero(self):
        result = bash(
            f"bash '{self.TRAIN}' src/train.py",
            env={"INFRA_MODE": "staging"},
        )
        assert result.returncode != 0
        assert "Unknown INFRA_MODE" in result.stderr


class TestStatus:
    STATUS = ROOT / "infra" / "scripts" / "status.sh"
    BASE_ENV = {
        "INFRA_MODE": "local",
        "PROJECT_ROOT": str(ROOT),
        "TF_VAR_project": "nix-ml-solo",
        "TF_VAR_environment": "dev",
        "MLFLOW_PORT": "5000",
        "JUPYTER_PORT": "8888",
        "INFERENCE_PORT": "5001",
        "MLFLOW_TRACKING_URI": "http://localhost:5000",
    }

    def test_exits_zero_in_local_mode(self):
        result = bash(f"bash '{self.STATUS}'", env=self.BASE_ENV)
        assert result.returncode == 0

    def test_shows_project_name(self):
        result = bash(f"bash '{self.STATUS}'", env=self.BASE_ENV)
        assert "nix-ml-solo" in result.stdout

    def test_shows_mode(self):
        result = bash(f"bash '{self.STATUS}'", env=self.BASE_ENV)
        assert "local" in result.stdout

    def test_shows_mlflow_not_running_when_down(self):
        result = bash(f"bash '{self.STATUS}'", env={**self.BASE_ENV, "MLFLOW_PORT": "19999"})
        assert "not running" in result.stdout


class TestMlflowClose:
    CLOSE = ROOT / "infra" / "scripts" / "mlflow" / "mlflow-close.sh"

    def test_exits_zero_when_no_tunnel(self):
        result = bash(f"bash '{self.CLOSE}'", env={"MLFLOW_PORT": "5000"})
        assert result.returncode == 0

    def test_reports_no_tunnel(self):
        result = bash(f"bash '{self.CLOSE}'", env={"MLFLOW_PORT": "5000"})
        assert "No tunnel running" in result.stdout


class TestShellcheck:
    @pytest.fixture(autouse=True)
    def require_shellcheck(self):
        if not shutil.which("shellcheck"):
            pytest.skip("shellcheck not in PATH — add to devenv packages")

    def test_all_scripts_pass_shellcheck(self):
        scripts = glob.glob(
            str(ROOT / "infra" / "scripts" / "**" / "*.sh"), recursive=True
        )
        failures = []
        for script in scripts:
            result = subprocess.run(
                ["shellcheck", "-S", "error", script],
                capture_output=True,
                text=True,
            )
            if result.returncode != 0:
                failures.append(f"{script}:\n{result.stdout.strip()}")
        assert not failures, "\n\n".join(failures)


class TestTfInit:
    def test_generates_correct_bucket_name(self, tmp_path):
        script = ROOT / "infra" / "scripts" / "aws" / "tf-init.sh"
        env = {
            "TF_VAR_project": "myproject",
            "TF_VAR_environment": "test",
            "TF_VAR_aws_region": "eu-west-1",
            "PROJECT_ROOT": str(tmp_path),
        }
        (tmp_path / "infra" / "terraform").mkdir(parents=True)
        bash(f"bash '{script}'", env=env)
        tfvars = (tmp_path / "infra" / "terraform" / "backend.tfvars").read_text()
        assert 'bucket         = "myproject-test-tfstate"' in tfvars
        assert 'region         = "eu-west-1"' in tfvars
        assert 'dynamodb_table = "myproject-test-tfstate-lock"' in tfvars
        assert "encrypt        = true" in tfvars
