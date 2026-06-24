{ config, pkgs, lib, ... }:

{
  # ── System ──────────────────────────────────────────────────────────────────

  system.stateVersion = "25.05";

  imports = [ <nixpkgs/nixos/modules/virtualisation/amazon-image.nix> ];

  ec2.hvm = true;

  # ── SSH ─────────────────────────────────────────────────────────────────────

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

  # ── Nix binary cache ─────────────────────────────────────────────────────────

  nix.settings = {
    substituters = [
      "https://cache.nixos.org"
      "s3://${nix_cache_bucket}?region=${aws_region}"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    ];
    trusted-users = [ "root" "ml" ];
    post-build-hook = "/etc/nix/post-build-hook.sh";
  };

  environment.etc."nix/post-build-hook.sh" = {
    mode = "0755";
    text = ''
      #!/bin/sh
      set -euf
      export IFS=' '
      exec nix copy --to "s3://${nix_cache_bucket}?region=${aws_region}" $OUT_PATHS
    '';
  };

  # ── MLflow ───────────────────────────────────────────────────────────────────

  environment.systemPackages = with pkgs; [
    (python3.withPackages (ps: with ps; [ mlflow boto3 ]))
    awscli2
    git
  ];

  systemd.services.mlflow = {
    description   = "MLflow Tracking Server";
    wantedBy      = [ "multi-user.target" ];
    after         = [ "network.target" ];

    environment = {
      AWS_DEFAULT_REGION   = "${aws_region}";
      MLFLOW_ARTIFACT_ROOT = "s3://${dvc_bucket_name}/mlflow";
    };

    serviceConfig = {
      User      = "ml";
      Restart   = "on-failure";
      ExecStart = ''
        $${pkgs.python3.withPackages (ps: [ ps.mlflow ps.boto3 ])}/bin/mlflow server \
          --host 127.0.0.1 \
          --port ${mlflow_port} \
          --default-artifact-root s3://${dvc_bucket_name}/mlflow \
          --backend-store-uri sqlite:////home/ml/mlflow.db
      '';
    };
  };

  environment.variables.AWS_DEFAULT_REGION = "${aws_region}";

  # ── User extensions ───────────────────────────────────────────────────────────
  # Set EC2_EXTRA_NIX_CONFIG in root devenv.nix to add packages, services, etc.
  # Example:
  #   env.EC2_EXTRA_NIX_CONFIG = ''
  #     environment.systemPackages = with pkgs; [ htop ripgrep ];
  #     services.prometheus.enable = true;
  #   '';
  ${extra_nix_config}
}
