"""devenv shell integration tests.

Each fixture starts devenv shell once and captures output — not once per test.
Marked slow; run with: pytest -m slow  (or just pytest tests/integration/)
"""

import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.parent
pytestmark = pytest.mark.slow


def devenv(cmd: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["devenv", "shell", "--", "bash", "-c", cmd],
        capture_output=True,
        text=True,
        cwd=ROOT,
    )


@pytest.fixture(scope="session")
def shell_env():
    """Dump all relevant env vars in a single devenv shell invocation."""
    result = devenv("""
        echo "INFRA_MODE=${INFRA_MODE:-}"
        echo "MLFLOW_PORT=${MLFLOW_PORT:-}"
        echo "JUPYTER_PORT=${JUPYTER_PORT:-}"
        echo "INFERENCE_PORT=${INFERENCE_PORT:-}"
        echo "MLFLOW_TRACKING_URI=${MLFLOW_TRACKING_URI:-}"
        echo "DVC_REMOTE_URL=${DVC_REMOTE_URL:-}"
        echo "PROJECT_ROOT=${PROJECT_ROOT:-}"
        echo "TF_VAR_project=${TF_VAR_project:-}"
        echo "TF_VAR_environment=${TF_VAR_environment:-}"
        echo "INFERENCE_SCRIPT=${INFERENCE_SCRIPT:-}"
    """)
    assert result.returncode == 0, result.stderr
    return dict(
        line.split("=", 1)
        for line in result.stdout.splitlines()
        if "=" in line
    )


@pytest.fixture(scope="session")
def shell_which():
    """Check PATH availability of all expected tools and scripts."""
    tools = [
        "python", "uv", "mlflow", "dvc", "aws", "jq", "mutagen",
        "mlflow-start", "mlflow-close", "mlflow-open",
        "train", "train-on-ec2", "train-status",
        "status", "setup", "deploy", "teardown", "restore",
        "tf-init", "tf-plan", "tf-apply", "tf-destroy", "tf-bootstrap",
        "nix-sync", "nix-cache-push", "nix-cache-pull",
        "sync", "sync-ec2", "sync-ec2-status", "sync-ec2-stop",
        "container-build", "jupyter",
        "aws-login", "aws-verify",
    ]
    lines = [
        f'command -v {t} >/dev/null 2>&1 && echo "{t}=ok" || echo "{t}=missing"'
        for t in tools
    ]
    result = devenv("\n".join(lines))
    assert result.returncode == 0, result.stderr
    return dict(
        line.split("=", 1)
        for line in result.stdout.splitlines()
        if "=" in line
    )


class TestShellEvaluates:
    def test_devenv_shell_exits_zero(self):
        result = devenv("true")
        assert result.returncode == 0


class TestEnvVars:
    def test_infra_mode_defaults_to_local(self, shell_env):
        assert shell_env["INFRA_MODE"] == "local"

    def test_mlflow_port(self, shell_env):
        assert shell_env["MLFLOW_PORT"] == "5000"

    def test_jupyter_port(self, shell_env):
        assert shell_env["JUPYTER_PORT"] == "8888"

    def test_inference_port(self, shell_env):
        assert shell_env["INFERENCE_PORT"] == "5001"

    def test_mlflow_tracking_uri(self, shell_env):
        assert shell_env["MLFLOW_TRACKING_URI"] == "http://localhost:5000"

    def test_dvc_remote_url(self, shell_env):
        assert "s3://" in shell_env["DVC_REMOTE_URL"]
        assert "dvc" in shell_env["DVC_REMOTE_URL"]

    def test_project_root_is_set(self, shell_env):
        assert shell_env["PROJECT_ROOT"] != ""

    def test_tf_var_project(self, shell_env):
        assert shell_env["TF_VAR_project"] == "nix-ml-solo"

    def test_tf_var_environment(self, shell_env):
        assert shell_env["TF_VAR_environment"] == "dev"

    def test_inference_script(self, shell_env):
        assert shell_env["INFERENCE_SCRIPT"] == "src/inference.py"


class TestToolsInPath:
    @pytest.mark.parametrize("tool", [
        "python", "uv", "mlflow", "dvc", "aws", "jq", "mutagen",
    ])
    def test_tool_available(self, shell_which, tool):
        assert shell_which.get(tool) == "ok", f"{tool} not found in PATH"


class TestScriptsInPath:
    @pytest.mark.parametrize("script", [
        "mlflow-start", "mlflow-close", "mlflow-open",
        "train", "train-on-ec2", "train-status",
        "status", "setup", "deploy", "teardown", "restore",
        "tf-init", "tf-plan", "tf-apply", "tf-destroy", "tf-bootstrap",
        "nix-sync", "nix-cache-push", "nix-cache-pull",
        "sync", "sync-ec2", "sync-ec2-status", "sync-ec2-stop",
        "container-build", "jupyter", "aws-login", "aws-verify",
    ])
    def test_script_in_path(self, shell_which, script):
        assert shell_which.get(script) == "ok", f"{script} not found in PATH"


class TestScriptBehaviourLocalMode:
    def test_status_exits_zero_in_local_mode(self):
        result = devenv("status")
        assert result.returncode == 0

    def test_train_requires_argument(self):
        result = devenv("train")
        assert result.returncode != 0

    def test_sync_requires_cloud_mode(self):
        result = devenv("sync")
        assert result.returncode != 0
        assert "cloud mode" in result.stderr

    def test_train_on_ec2_requires_cloud_mode(self):
        result = devenv("train-on-ec2 somescript.py")
        assert result.returncode != 0
        assert "cloud mode" in result.stderr
