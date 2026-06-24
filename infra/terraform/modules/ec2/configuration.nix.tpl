{ config, pkgs, lib, ... }:

let
  # Pin devenv to the same nixpkgs commit as local dev (devenv.lock).
  # This ensures EC2 runs the identical devenv binary that generated the lock,
  # so lock-file format and input requirements are always compatible.
  pinnedPkgs = import (builtins.fetchTarball {
    url    = "https://github.com/NixOS/nixpkgs/archive/${nixpkgs_rev}.tar.gz";
    sha256 = "${nixpkgs_nar_hash}";
  }) { system = "x86_64-linux"; config.allowUnfree = true; };
in
{
  system.stateVersion = "25.05";
  imports = [ <nixpkgs/nixos/modules/virtualisation/amazon-image.nix> ];
  ec2.hvm = true;

  # EC2 has no physical console — also disables the kbd.gzip bug in nixos-25.05 console.nix
  console.enable = false;

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
    extra-experimental-features = [ "nix-command" "flakes" ];
  };

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

  # ── System packages ───────────────────────────────────────────────────────────
  # Only bootstrapping tools + EC2-specific services.
  # All ML/DS packages come from devenv.nix via the devenv-build service below.

  environment.systemPackages = [
    pinnedPkgs.devenv   # same version as local — must match devenv.lock format
    pkgs.git
    pkgs.litestream
  ];
  environment.variables.AWS_DEFAULT_REGION = "${aws_region}";

  # ── Directory scaffolding ────────────────────────────────────────────────────

  systemd.tmpfiles.rules = [
    "d /home/ml/project           0755 ml users -"
    "d /home/ml/.local            0755 ml users -"
    "d /home/ml/.local/bin        0755 ml users -"
    "d /home/ml/.local/share      0755 ml users -"
    "d /home/ml/.local/share/uv   0755 ml users -"
  ];

  # ── devenv environment ────────────────────────────────────────────────────────
  # devenv.nix + devenv.lock are pushed to /home/ml/project by nixos-rebuild.
  # This service builds the devenv profile so services below can use the tools.
  # Uses S3 nix cache — run `nix-sync` locally first to pre-populate it.

  systemd.services.devenv-build = {
    description = "Build devenv environment from devenv.nix";
    wantedBy    = [ "mlflow-install.service" ];
    before      = [ "mlflow-install.service" ];
    after       = [ "network-online.target" ];
    requires    = [ "network-online.target" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      User            = "ml";
      WorkingDirectory = "/home/ml/project";
      Environment     = [ "HOME=/home/ml" "AWS_DEFAULT_REGION=${aws_region}" ];
      ExecStart       = "/run/current-system/sw/bin/devenv shell -- echo devenv-profile-ready";
    };
  };

  # ── MLflow ───────────────────────────────────────────────────────────────────

  environment.etc."mlflow-start.sh" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      exec /home/ml/.local/bin/mlflow server \
        --host 127.0.0.1 \
        --port ${mlflow_port} \
        --workers 1 \
        --default-artifact-root s3://${dvc_bucket_name}/mlflow \
        --backend-store-uri sqlite:////home/ml/mlflow.db
    '';
  };

  swapDevices = [{ device = "/swapfile"; size = 2048; }];

  systemd.services.mlflow-install = {
    description = "Install MLflow via uv (once per boot)";
    wantedBy    = [ "mlflow.service" ];
    before      = [ "mlflow.service" ];
    after       = [ "network-online.target" "devenv-build.service" ];
    requires    = [ "network-online.target" "devenv-build.service" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      User            = "ml";
      Environment     = [ "HOME=/home/ml" ];
      ExecStart       = "/home/ml/project/.devenv/profile/bin/uv tool install --quiet mlflow";
    };
  };

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
      ExecStart       = "/bin/sh -c '[ -f /home/ml/mlflow.db ] || /run/current-system/sw/bin/litestream restore -if-replica-exists -o /home/ml/mlflow.db s3://${dvc_bucket_name}/mlflow-litestream/mlflow.db'";
    };
  };

  systemd.services.mlflow = {
    description = "MLflow Tracking Server (litestream-replicated)";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "network.target" "mlflow-install.service" "mlflow-restore.service" ];
    wants    = [ "mlflow-restore.service" ];
    requires = [ "mlflow-install.service" ];
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
