# Contributing to nix-ml-solo

Thank you for your interest in contributing!

## Getting started

You need [Nix](https://nixos.org/download) with flakes enabled and [direnv](https://direnv.net/).

```bash
git clone https://github.com/thatbagu/nix-ml-solo
cd nix-ml-solo
direnv allow
```

The devenv shell activates automatically. All tools (tofu, gum, mutagen, aws-nuke, DVC) are pinned in `devenv.lock`.

## What to work on

- Browse [open issues](../../issues)
- Bugs labelled `good first issue` are a good starting point
- Open an issue before starting significant work — alignment upfront saves time

## Submitting changes

1. Fork and create a branch from `main`
2. Make your changes
3. Test locally — for infra scripts, at minimum verify `shellcheck` passes:
   ```bash
   shellcheck infra/scripts/**/*.sh infra/scripts/*.sh
   ```
4. Open a pull request with a clear description of what and why

## Code style

**Nix**: follow [nixpkgs formatting conventions](https://github.com/NixOS/nixpkgs/blob/master/CONTRIBUTING.md#nix-expression-style-guide) — 2-space indentation, `let … in` for local bindings, descriptive attribute names.

**Bash**: `set -euo pipefail` at the top of every script. Avoid bashisms that aren't in POSIX where possible. No silent failures — every non-trivial command should have `|| true` or explicit error handling. Run `shellcheck` before submitting.

**Commit messages**: short imperative subject line (≤72 chars), present tense. No period at the end.

## Reporting bugs

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include:

- Your OS and Nix version (`nix --version`)
- The exact command you ran
- Full output (paste as text, not a screenshot)

## License

By contributing, you agree that your contributions will be licensed under the [Apache License 2.0](LICENSE).
