{
  pkgs,
  lib ? pkgs.lib,
  config,
  ...
}:

let
  devenvRoot = "${config.env.DEVENV_ROOT}/.devenv-configs/";
  projectRoot = "${config.env.DEVENV_ROOT}/";
in
{
  imports = [ ./scripts.nix ];

  packages = [
    pkgs.awscli2
    pkgs.tenv
    pkgs.jq
    pkgs.docker
  ];

  env = {
    PROJECT_ROOT = projectRoot;

    TENV_AUTO_INSTALL = "true";
    TOFUENV_TOFU_VERSION = "1.9.1";

    AWS_CONFIG_DIR = "${devenvRoot}.aws/";
    AWS_CONFIG_FILE = "${devenvRoot}.aws/config";
    AWS_SHARED_CREDENTIALS_FILE = "${devenvRoot}.aws/credentials";

    AWS_DEFAULT_REGION = "us-east-1";
    # AWS_AUTH_METHOD, AWS_SSO_START_URL, AWS_SSO_REGION — set by setup wizard in local.env

    # ── Infra mode ───────────────────────────────────────────────────────────
    # local = MLflow+DVC only, train runs python directly, deploy serves locally
    # cloud = full AWS stack, train → SageMaker, deploy → endpoint
    # Override in root devenv.nix: env.INFRA_MODE = "cloud";
    INFRA_MODE = "local";

    # Default training script — override per-project or pass as argument to train
    TRAINING_SCRIPT = "";

    # Inference script for deploy (cloud mode).
    # Inference script — overridden in root devenv.nix to src/inference.py
    INFERENCE_SCRIPT = "";

    TF_VAR_infra_mode = "local";

    AWS_PROFILE = "ml-solo";

    # ── Terraform vars (TF_VAR_* is picked up automatically by tofu/terraform) ──
    TF_VAR_project = "nix-ml-solo";
    TF_VAR_environment = "dev";
    TF_VAR_aws_region = "us-east-1";
    TF_VAR_aws_profile = "ml-solo";
    TF_VAR_ec2_instance_type = "t3.medium";
    TF_VAR_mlflow_port = "5000";

    # Set after first tf-apply — leave empty until then
    TF_VAR_sagemaker_instance_type = "ml.t2.medium";
    TF_VAR_sagemaker_model_image_uri = "";
    TF_VAR_sagemaker_model_s3_uri = "";
    TF_VAR_sagemaker_training_image_uri = "";

    # TF_VAR_ssh_public_key — set by the setup wizard into .devenv-configs/local.env

    # Extra NixOS config for the EC2 VM — override in root devenv.nix to add
    # packages, services, etc. without touching the Terraform module directly.
    # Example in root devenv.nix:
    #   env.TF_VAR_ec2_extra_nix_config = ''
    #     environment.systemPackages = with pkgs; [ htop ripgrep ];
    #     services.prometheus.enable = true;
    #   '';
    TF_VAR_ec2_extra_nix_config = "";
  };

  enterShell = builtins.readFile ./scripts/enter-shell.sh;
}
