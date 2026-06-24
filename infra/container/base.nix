# Docker base image for SageMaker containers.
# Built from the exact nixpkgs commit in devenv.lock — run via container-build.
# Python packages (mlflow, boto3, etc.) are added by uv sync on top in the Dockerfile.
{ nixpkgs_rev, nixpkgs_nar_hash }:
let
  pkgs = import (builtins.fetchTarball {
    url    = "https://github.com/NixOS/nixpkgs/archive/${nixpkgs_rev}.tar.gz";
    sha256 = nixpkgs_nar_hash;
  }) { system = "x86_64-linux"; };
in
pkgs.dockerTools.buildLayeredImage {
  name     = "ml-solo-base";
  tag      = builtins.substring 0 8 nixpkgs_rev;
  contents = with pkgs; [
    awscli2
    uv
    python312
    bash
    coreutils
    cacert
    git
  ];
  config.Env = [
    "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    "GIT_SSL_CAINFO=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
    "PYTHONUNBUFFERED=1"
  ];
}
