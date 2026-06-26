"""Tests for _lib.sh helper functions — validators, persistence, AWS profile writers."""

import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.parent
LIB = ROOT / "infra" / "scripts" / "_lib.sh"


def lib(call: str, env: dict | None = None, setup: str = "") -> subprocess.CompletedProcess:
    script = f"source '{LIB}'"
    if setup:
        script += f"\n{setup}"
    script += f"\n{call}"
    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        env={**os.environ, **(env or {})},
        cwd=ROOT,
    )


def valid(fn: str, value: str) -> bool:
    return lib(f"{fn} '{value}'").returncode == 0


class TestValidRegion:
    def test_valid_us_east_1(self):
        assert valid("_valid_region", "us-east-1")

    def test_valid_eu_west_1(self):
        assert valid("_valid_region", "eu-west-1")

    def test_valid_ap_southeast_1(self):
        assert valid("_valid_region", "ap-southeast-1")

    def test_rejects_made_up_region(self):
        assert not valid("_valid_region", "xx-fake-1")

    def test_rejects_empty(self):
        assert not valid("_valid_region", "")

    def test_rejects_partial_match(self):
        assert not valid("_valid_region", "us-east")


class TestValidProjectName:
    def test_valid_simple(self):
        assert valid("_valid_project_name", "myproject")

    def test_valid_with_hyphens(self):
        assert valid("_valid_project_name", "nix-ml-solo")

    def test_valid_with_numbers(self):
        assert valid("_valid_project_name", "ml2024")

    def test_rejects_uppercase(self):
        assert not valid("_valid_project_name", "MyProject")

    def test_rejects_starts_with_number(self):
        assert not valid("_valid_project_name", "1project")

    def test_rejects_too_short(self):
        assert not valid("_valid_project_name", "ab")

    def test_rejects_underscore(self):
        assert not valid("_valid_project_name", "my_project")


class TestValidEc2Type:
    def test_valid_t3_small(self):
        assert valid("_valid_ec2_type", "t3.small")

    def test_valid_m5_xlarge(self):
        assert valid("_valid_ec2_type", "m5.xlarge")

    def test_valid_g4dn_xlarge(self):
        assert valid("_valid_ec2_type", "g4dn.xlarge")

    def test_valid_c5_4xlarge(self):
        assert valid("_valid_ec2_type", "c5.4xlarge")

    def test_rejects_missing_dot(self):
        assert not valid("_valid_ec2_type", "t3small")

    def test_rejects_made_up_type(self):
        assert not valid("_valid_ec2_type", "z9.superfast")


class TestValidAwsKeyId:
    def test_valid_akia_key(self):
        assert valid("_valid_aws_key_id", "AKIAIOSFODNN7EXAMPLE")

    def test_valid_asia_key(self):
        assert valid("_valid_aws_key_id", "ASIAIOSFODNN7EXAMPL1")

    def test_rejects_wrong_prefix(self):
        assert not valid("_valid_aws_key_id", "XKIAIOSFODNN7EXAMPLE")

    def test_rejects_too_short(self):
        assert not valid("_valid_aws_key_id", "AKIASHORT")

    def test_rejects_lowercase(self):
        assert not valid("_valid_aws_key_id", "akiaiosfodnn7example")


class TestValidAccountId:
    def test_valid_12_digits(self):
        assert valid("_valid_account_id", "123456789012")

    def test_rejects_11_digits(self):
        assert not valid("_valid_account_id", "12345678901")

    def test_rejects_13_digits(self):
        assert not valid("_valid_account_id", "1234567890123")

    def test_rejects_letters(self):
        assert not valid("_valid_account_id", "1234567890ab")


class TestValidHttpsUrl:
    def test_valid_https(self):
        assert valid("_valid_https_url", "https://example.com")

    def test_rejects_http(self):
        assert not valid("_valid_https_url", "http://example.com")

    def test_rejects_bare_domain(self):
        assert not valid("_valid_https_url", "example.com")


class TestSave:
    def test_creates_new_entry(self, tmp_path):
        env_file = tmp_path / "local.env"
        env_file.touch()
        lib("_save 'MYVAR' 'myvalue'", env={"LOCAL_ENV": str(env_file)})
        assert 'export MYVAR="myvalue"' in env_file.read_text()

    def test_updates_existing_entry(self, tmp_path):
        env_file = tmp_path / "local.env"
        env_file.write_text('export MYVAR="oldvalue"\n')
        lib("_save 'MYVAR' 'newvalue'", env={"LOCAL_ENV": str(env_file)})
        text = env_file.read_text()
        assert "newvalue" in text
        assert "oldvalue" not in text

    def test_update_does_not_duplicate(self, tmp_path):
        env_file = tmp_path / "local.env"
        env_file.write_text('export MYVAR="oldvalue"\n')
        lib("_save 'MYVAR' 'newvalue'", env={"LOCAL_ENV": str(env_file)})
        assert env_file.read_text().count("MYVAR") == 1


class TestAlreadySet:
    def test_true_when_different_from_default(self):
        result = lib("_already_set 'MYVAR' 'default'", env={"MYVAR": "custom"})
        assert result.returncode == 0

    def test_false_when_equals_default(self):
        result = lib("_already_set 'MYVAR' 'default'", env={"MYVAR": "default"})
        assert result.returncode != 0

    def test_false_when_empty(self):
        result = lib("_already_set 'MYVAR' 'default'", env={"MYVAR": ""})
        assert result.returncode != 0


class TestWriteIamProfile:
    def _setup(self, tmp_path: Path) -> Path:
        aws = tmp_path / ".aws"
        aws.mkdir()
        (aws / "config").touch()
        (aws / "credentials").touch()
        return tmp_path

    def test_writes_profile_to_config(self, tmp_path):
        configs = self._setup(tmp_path)
        lib(
            "_write_iam_profile 'ml-solo' 'AKIAIOSFODNN7EXAMPLE' 'wJalrXUtnFEMI' 'us-east-1'",
            env={"CONFIGS": str(configs)},
        )
        config = (configs / ".aws" / "config").read_text()
        assert "[profile ml-solo]" in config
        assert "region = us-east-1" in config

    def test_writes_credentials(self, tmp_path):
        configs = self._setup(tmp_path)
        lib(
            "_write_iam_profile 'ml-solo' 'AKIAIOSFODNN7EXAMPLE' 'wJalrXUtnFEMI' 'us-east-1'",
            env={"CONFIGS": str(configs)},
        )
        creds = (configs / ".aws" / "credentials").read_text()
        assert "[ml-solo]" in creds
        assert "aws_access_key_id = AKIAIOSFODNN7EXAMPLE" in creds

    def test_idempotent(self, tmp_path):
        configs = self._setup(tmp_path)
        cmd = "_write_iam_profile 'ml-solo' 'AKIAIOSFODNN7EXAMPLE' 'secret' 'us-east-1'"
        lib(cmd, env={"CONFIGS": str(configs)})
        lib(cmd, env={"CONFIGS": str(configs)})
        assert (configs / ".aws" / "config").read_text().count("[profile ml-solo]") == 1


class TestWriteSsoProfile:
    def _setup(self, tmp_path: Path) -> Path:
        aws = tmp_path / ".aws"
        aws.mkdir()
        (aws / "config").touch()
        return tmp_path

    def test_writes_sso_profile(self, tmp_path):
        configs = self._setup(tmp_path)
        lib(
            "_write_sso_profile 'ml-solo' 'https://myorg.awsapps.com/start' "
            "'us-east-1' '123456789012' 'PowerUserAccess' 'us-east-1'",
            env={"CONFIGS": str(configs)},
        )
        config = (configs / ".aws" / "config").read_text()
        assert "[profile ml-solo]" in config
        assert "sso_start_url = https://myorg.awsapps.com/start" in config
        assert "sso_account_id = 123456789012" in config

    def test_idempotent(self, tmp_path):
        configs = self._setup(tmp_path)
        cmd = (
            "_write_sso_profile 'ml-solo' 'https://x.awsapps.com/start' "
            "'us-east-1' '123456789012' 'Admin' 'us-east-1'"
        )
        lib(cmd, env={"CONFIGS": str(configs)})
        lib(cmd, env={"CONFIGS": str(configs)})
        assert (configs / ".aws" / "config").read_text().count("[profile ml-solo]") == 1


class TestSyncDevenvLockPins:
    def test_exports_nixpkgs_rev(self):
        result = lib(
            '_sync_devenv_lock_pins && echo "rev=$TF_VAR_nixpkgs_rev"',
            env={"DEVENV_ROOT": str(ROOT)},
        )
        pairs = dict(l.split("=", 1) for l in result.stdout.splitlines() if "=" in l)
        assert len(pairs.get("rev", "")) == 40

    def test_exports_nar_hash(self):
        result = lib(
            '_sync_devenv_lock_pins && echo "hash=$TF_VAR_nixpkgs_nar_hash"',
            env={"DEVENV_ROOT": str(ROOT)},
        )
        pairs = dict(l.split("=", 1) for l in result.stdout.splitlines() if "=" in l)
        assert pairs.get("hash", "").startswith("sha256-")

    def test_graceful_when_no_lock_file(self, tmp_path):
        result = lib(
            "_sync_devenv_lock_pins",
            env={"DEVENV_ROOT": str(tmp_path)},
        )
        assert result.returncode == 0
