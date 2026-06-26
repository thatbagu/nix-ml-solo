# SageMaker runtime image — the devenv profile closure is baked in as Docker
# layers (one per Nix package, via streamLayeredImage). Unchanged packages are
# cached by ECR and not re-pushed/re-pulled when devenv.nix changes.
# Cold start = Docker layer pull (parallel, cached) + uv sync (~1-2 min).
{ nixpkgs_rev, nixpkgs_nar_hash, devenv_profile }:
let
  pkgs = import (builtins.fetchTarball {
    url    = "https://github.com/NixOS/nixpkgs/archive/${nixpkgs_rev}.tar.gz";
    sha256 = nixpkgs_nar_hash;
  }) { system = "x86_64-linux"; };

  profile = builtins.storePath devenv_profile;
in
pkgs.dockerTools.buildLayeredImage {
  name     = "ml-solo-base";
  tag      = builtins.substring 0 8 nixpkgs_rev;

  # Each package in the devenv profile closure gets its own Docker layer.
  # Only layers whose content hash changed are re-pushed to ECR.
  contents = with pkgs; [
    nix
    bash
    coreutils
    cacert
    profile
  ];

  extraCommands = ''
    mkdir -p nix/store nix/var/nix/profiles nix/var/nix/gcroots
    mkdir -p etc/nix
    echo 'sandbox = false'                                   > etc/nix/nix.conf
    echo 'trusted-users = root'                             >> etc/nix/nix.conf
    echo 'extra-experimental-features = nix-command flakes' >> etc/nix/nix.conf
  '';

  config = {
    Env = [
      "PATH=${profile}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "NIX_SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      "PYTHONUNBUFFERED=1"
    ];
  };
}
