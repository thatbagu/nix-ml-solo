# touch
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

  # Infra tooling — local only. Not pushed to EC2.
  # Shared DS/ML packages live in root devenv.nix.
  packages = [
    pkgs.tenv      # Terraform/OpenTofu version manager
    pkgs.jq        # JSON CLI
    pkgs.crane     # Layer append/mutate and manifest format conversion
    pkgs.skopeo    # Push nixpkgs buildLayeredImage tarballs to ECR (crane can't parse them)
    pkgs.gum       # TUI prompts for setup wizard
    pkgs.mutagen   # Bidirectional real-time sync local <-> EC2
    pkgs.aws-nuke  # Nuclear teardown — deletes all AWS resources in the account
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
    INFRA_MODE = lib.mkDefault "local";

    # Default training script — override per-project or pass as argument to train
    TRAINING_SCRIPT = lib.mkDefault "";

    # Inference script for deploy (cloud mode).
    # Inference script — overridden in root devenv.nix to src/inference.py
    INFERENCE_SCRIPT = lib.mkDefault "";

    TF_VAR_infra_mode = lib.mkDefault "local";

    AWS_PROFILE = "ml-solo";

    # ── Terraform vars (TF_VAR_* is picked up automatically by tofu/terraform) ──
    TF_VAR_project = "nix-ml-solo";
    TF_VAR_environment = "dev";
    TF_VAR_aws_region = "us-east-1";
    TF_VAR_aws_profile = "ml-solo";
    TF_VAR_ec2_instance_type = "t3.small";
    TF_VAR_mlflow_port = "5000";

    # Set after first tf-apply — leave empty until then
    # ── SageMaker inference endpoint ─────────────────────────────────────────
    # Override any of these in root devenv.nix to customise the endpoint.

    # Instance type for inference. GPU options: ml.g4dn.xlarge, ml.g5.xlarge
    TF_VAR_sagemaker_instance_type  = lib.mkDefault "ml.t2.medium";
    # Instance type for SageMaker training jobs
    SAGEMAKER_TRAINING_INSTANCE     = lib.mkDefault "ml.m5.xlarge";
    # Number of instances to start with
    TF_VAR_sagemaker_instance_count = lib.mkDefault "1";

    # Auto-scaling: set min_capacity > 0 to enable.
    # Scale metric: SageMakerVariantInvocationsPerInstance (requests/min per instance)
    TF_VAR_sagemaker_min_capacity                      = lib.mkDefault "0";   # 0 = disabled
    TF_VAR_sagemaker_max_capacity                      = lib.mkDefault "4";
    TF_VAR_sagemaker_target_invocations_per_instance   = lib.mkDefault "100";
    TF_VAR_sagemaker_scale_out_cooldown                = lib.mkDefault "60";
    TF_VAR_sagemaker_scale_in_cooldown                 = lib.mkDefault "300";

    TF_VAR_sagemaker_model_image_uri    = lib.mkDefault "";
    TF_VAR_sagemaker_model_s3_uri       = lib.mkDefault "";
    TF_VAR_sagemaker_training_image_uri = lib.mkDefault "";

    # Set to "true" to expose the endpoint via API Gateway (no AWS auth required).
    # false = private (access via AWS SDK/CLI with IAM only)
    # true  = public (HTTPS URL callable by anyone)
    TF_VAR_sagemaker_public_endpoint        = lib.mkDefault "false";
    TF_VAR_sagemaker_public_endpoint_binary = lib.mkDefault "false";

    # Deployment strategy for endpoint updates.
    # blue_green — all traffic cuts over at once after new instances pass /ping
    # canary     — small % first (canary_percent), then full cutover after wait
    # linear     — shift traffic in equal steps (linear_step_percent) with wait between each
    # shadow     — requires separate shadow variant setup; not configured here
    TF_VAR_sagemaker_deployment_strategy              = lib.mkDefault "blue_green";
    TF_VAR_sagemaker_deployment_canary_percent        = lib.mkDefault "10";
    TF_VAR_sagemaker_deployment_linear_step_percent   = lib.mkDefault "25";
    TF_VAR_sagemaker_deployment_wait_interval_seconds = lib.mkDefault "300";

    # Set by the setup wizard into .devenv-configs/local.env:
    # TF_VAR_ssh_public_key — EC2 public key content
    # SSH_IDENTITY_FILE     — path to the matching private key (~/.ssh/<project>)
    SSH_IDENTITY_FILE = lib.mkDefault "";

    # Extra NixOS config for the EC2 VM — override in root devenv.nix to add
    # services or packages that don't belong in ec2PackageList.
    # Example:
    #   env.TF_VAR_ec2_extra_nix_config = ''
    #     services.prometheus.enable = true;
    #   '';
    TF_VAR_ec2_extra_nix_config = "";
  };

  enterShell = builtins.readFile ./scripts/enter-shell.sh;
}
