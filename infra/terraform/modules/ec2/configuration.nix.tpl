{ config, lib, ... }:

let
  # Pinned to the same nixpkgs commit as devenv.lock — single source of truth
  # for system packages across local dev, EC2, and Docker builds.
  # To add overlays: pkgs.extend (final: prev: { ... })
  pkgs = import (builtins.fetchTarball
    "https://github.com/NixOS/nixpkgs/archive/${nixpkgs_rev}.tar.gz"
  ) { system = "x86_64-linux"; config.allowUnfree = true; };
in
{
  nixpkgs.pkgs = pkgs;

  system.stateVersion = "25.05";
  imports = [ <nixpkgs/nixos/modules/virtualisation/amazon-image.nix> ];
  ec2.hvm = true;

  # ── SSH ──────────────────────────────────────────────────────────────────────

  users.users.ml = {
    isNormalUser   = true;
    extraGroups    = [ "wheel" ];
    openssh.authorizedKeys.keys = [ "${ssh_public_key}" ];
  };

  security.sudo.wheelNeedsPassword = false;

  services.openssh = {
    enable      = true;
    settings.PasswordAuthentication = false;
  };

  # ── Nix ──────────────────────────────────────────────────────────────────────

  nix.settings = {
    substituters        = [ "https://cache.nixos.org" "s3://${nix_cache_bucket}?region=${aws_region}" ];
    trusted-public-keys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
    trusted-users       = [ "root" "ml" ];
    extra-experimental-features = [ "nix-command" ];
  };

  # Post-build hook pushes built paths to the S3 binary cache.
  # Uses || true so a transient failure never blocks a nixos-rebuild.
  environment.etc."nix/post-build-hook.sh" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      set -uf
      export IFS=' '
      nix copy --to "s3://${nix_cache_bucket}?region=${aws_region}" $OUT_PATHS || true
    '';
  };

  nix.settings.post-build-hook = "/etc/nix/post-build-hook.sh";

  # Allows uv's bundled Python and other generic Linux binaries to run on NixOS.
  programs.nix-ld.enable = true;

  # ── Packages ─────────────────────────────────────────────────────────────────

  environment.systemPackages = with pkgs; [ awscli2 git uv python3 litestream ];

  environment.variables.AWS_DEFAULT_REGION = "${aws_region}";

  # ── Home directory scaffolding ────────────────────────────────────────────────
  # Must create parent dirs explicitly — tmpfiles only chowns the leaf.

  systemd.tmpfiles.rules = [
    "d /home/ml/.local            0755 ml users -"
    "d /home/ml/.local/bin        0755 ml users -"
    "d /home/ml/.local/share      0755 ml users -"
    "d /home/ml/.local/share/uv   0755 ml users -"
  ];

  # ── MLflow ───────────────────────────────────────────────────────────────────

  # Litestream continuously replicates the SQLite DB to S3 (WAL streaming).
  # No FUSE — SQLite runs on local EBS with proper locking; S3 is pure backup.
  # DB survives tf-destroy: mlflow-restore pulls it back on next boot.

  environment.etc."mlflow-start.sh" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      exec /home/ml/.local/bin/mlflow server \
        --host 127.0.0.1 \
        --port ${mlflow_port} \
        --default-artifact-root s3://${dvc_bucket_name}/mlflow \
        --backend-store-uri sqlite:////home/ml/mlflow.db
    '';
  };

  # mlflow is installed via uv (PyPI wheel — includes pre-built JS UI).
  # Oneshot so uv only runs once per boot, not on every mlflow restart.
  systemd.services.mlflow-install = {
    description = "Install MLflow via uv (once per boot)";
    wantedBy    = [ "mlflow.service" ];
    before      = [ "mlflow.service" ];
    after       = [ "network-online.target" ];
    requires    = [ "network-online.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      User            = "ml";
      Environment     = [ "HOME=/home/ml" ];
      ExecStart       = "/run/current-system/sw/bin/uv tool install --quiet mlflow";
    };
  };

  # Restores DB from S3 on first boot (or after tf-destroy).
  # -if-replica-exists is a no-op when no S3 replica exists yet.
  systemd.services.mlflow-restore = {
    description = "Restore MLflow database from S3 litestream replica";
    wantedBy    = [ "mlflow.service" ];
    before      = [ "mlflow.service" ];
    after       = [ "network-online.target" ];
    requires    = [ "network-online.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      User            = "ml";
      Environment     = [ "HOME=/home/ml" "AWS_DEFAULT_REGION=${aws_region}" ];
      ExecStart       = "/run/current-system/sw/bin/litestream restore -if-replica-exists -o /home/ml/mlflow.db s3://${dvc_bucket_name}/mlflow-litestream/mlflow.db";
    };
  };

  systemd.services.mlflow = {
    description = "MLflow Tracking Server (litestream-replicated)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network.target" "mlflow-install.service" "mlflow-restore.service" ];
    requires    = [ "mlflow-install.service" "mlflow-restore.service" ];

    environment = {
      HOME               = "/home/ml";
      AWS_DEFAULT_REGION = "${aws_region}";
    };

    serviceConfig = {
      User      = "ml";
      Restart   = "on-failure";
      ExecStart = "/run/current-system/sw/bin/litestream replicate -exec /etc/mlflow-start.sh /home/ml/mlflow.db s3://${dvc_bucket_name}/mlflow-litestream/mlflow.db";
    };
  };

  # ── User extensions ───────────────────────────────────────────────────────────
  ${extra_nix_config}
}
