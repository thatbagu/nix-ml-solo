"""Local mode smoke tests — MLflow and training without cloud infra.

Marked slow: these start real processes. Run with: pytest -m slow
"""

import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

import pytest
import requests

ROOT = Path(__file__).parent.parent.parent
pytestmark = pytest.mark.slow


@pytest.fixture(scope="module")
def mlflow_server(tmp_path_factory):
    """Start a local MLflow server and yield its URI."""
    tmp = tmp_path_factory.mktemp("mlflow")
    proc = subprocess.Popen(
        [
            sys.executable, "-m", "mlflow", "server",
            "--host", "127.0.0.1",
            "--port", "15000",
            "--backend-store-uri", f"sqlite:///{tmp}/mlflow.db",
            "--default-artifact-root", str(tmp / "artifacts"),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    uri = "http://127.0.0.1:15000"
    for _ in range(60):
        try:
            if requests.get(f"{uri}/health", timeout=1).status_code == 200:
                break
        except Exception:
            pass
        time.sleep(0.5)
    else:
        proc.terminate()
        pytest.fail("MLflow server did not start in time")

    yield uri
    proc.terminate()
    proc.wait()


class TestMlflowLocal:
    def test_server_health(self, mlflow_server):
        resp = requests.get(f"{mlflow_server}/health")
        assert resp.status_code == 200

    def test_create_experiment(self, mlflow_server):
        import mlflow
        mlflow.set_tracking_uri(mlflow_server)
        exp_id = mlflow.create_experiment("test-experiment")
        assert exp_id is not None

    def test_log_and_retrieve_metric(self, mlflow_server):
        import mlflow
        mlflow.set_tracking_uri(mlflow_server)
        mlflow.set_experiment("test-experiment")
        with mlflow.start_run() as run:
            mlflow.log_metric("accuracy", 0.95)
            run_id = run.info.run_id

        client = mlflow.tracking.MlflowClient(mlflow_server)
        metric = client.get_metric_history(run_id, "accuracy")[0]
        assert metric.value == pytest.approx(0.95)


class TestLocalTrain:
    def test_trivial_script_runs(self, mlflow_server, tmp_path):
        script = tmp_path / "train.py"
        script.write_text(
            f"""
import mlflow
mlflow.set_tracking_uri("{mlflow_server}")
with mlflow.start_run():
    mlflow.log_metric("loss", 0.42)
"""
        )
        result = subprocess.run(
            [sys.executable, str(script)],
            capture_output=True,
            text=True,
            env={**os.environ, "MLFLOW_TRACKING_URI": mlflow_server},
        )
        assert result.returncode == 0, result.stderr
