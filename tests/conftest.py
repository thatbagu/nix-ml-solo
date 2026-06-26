import os
from pathlib import Path
import pytest

PROJECT_ROOT = Path(__file__).parent.parent


@pytest.fixture
def project_root():
    return PROJECT_ROOT


@pytest.fixture
def env_local(monkeypatch):
    monkeypatch.setenv("INFRA_MODE", "local")
    monkeypatch.delenv("SSH_IDENTITY_FILE", raising=False)


@pytest.fixture
def env_cloud(tmp_path, monkeypatch):
    key = tmp_path / "id_ed25519"
    key.touch()
    monkeypatch.setenv("INFRA_MODE", "cloud")
    monkeypatch.setenv("SSH_IDENTITY_FILE", str(key))
