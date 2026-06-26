"""Structural validation — no infra required."""

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.parent
DOCS = ROOT / "docs"


class TestDocsCompleteness:
    def _summary_links(self):
        summary = (DOCS / "SUMMARY.md").read_text()
        return re.findall(r"\(\./([\w\-/]+\.md)\)", summary)

    def test_summary_exists(self):
        assert (DOCS / "SUMMARY.md").exists()

    def test_all_summary_pages_exist(self):
        missing = [
            path for path in self._summary_links()
            if not (DOCS / path).exists()
        ]
        assert missing == [], f"Missing doc pages: {missing}"

    def test_book_toml_exists(self):
        assert (DOCS / "book.toml").exists()


class TestReleasePleaseConfig:
    def test_config_is_valid_json(self):
        data = json.loads((ROOT / "release-please-config.json").read_text())
        assert "release-type" in data
        assert "packages" in data

    def test_manifest_is_valid_json(self):
        data = json.loads((ROOT / ".release-please-manifest.json").read_text())
        assert "." in data

    def test_manifest_version_is_semver(self):
        data = json.loads((ROOT / ".release-please-manifest.json").read_text())
        version = data["."]
        assert re.match(r"^\d+\.\d+\.\d+", version), f"Not semver: {version}"


class TestGitignore:
    def _entries(self):
        return (ROOT / ".gitignore").read_text().splitlines()

    def test_devenv_ignored(self):
        assert any(".devenv/" in line for line in self._entries())

    def test_backend_tfvars_ignored(self):
        assert any(
            "backend.tfvars" in line and not line.startswith("#")
            for line in self._entries()
        )

    def test_tf_state_ignored(self):
        assert any("terraform.tfstate" in line for line in self._entries())


class TestLicenseAndReadme:
    def test_license_is_mit(self):
        text = (ROOT / "LICENSE").read_text()
        assert "MIT License" in text

    def test_readme_has_docs_link(self):
        text = (ROOT / "README.md").read_text()
        assert "thatbagu.github.io/nix-ml-solo" in text

    def test_security_md_has_contact_email(self):
        text = (ROOT / "SECURITY.md").read_text()
        assert "egor@mlship.dev" in text
