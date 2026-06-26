# Cloud Mode

Cloud mode provisions an EC2 instance running NixOS alongside S3, ECR, and an optional SageMaker endpoint.

## What gets created

Running `tf-apply` creates:

| Resource             | Purpose                                                    |
|----------------------|------------------------------------------------------------|
| EC2 (NixOS)          | Hosts MLflow server; SSH tunnel for local access           |
| S3 (DVC)             | Data versioning remote                                     |
| S3 (Nix cache)       | Binary cache shared between laptop and EC2                 |
| ECR                  | Container registry for training/inference images           |
| SageMaker endpoint   | Inference (off by default)                                 |
| VPC endpoints        | ECR + S3 gateway so SageMaker containers don't need NAT    |

## Provisioning

```sh
tf-bootstrap       # create S3 state bucket + DynamoDB lock table (once)
tf-init            # initialise OpenTofu with the S3 backend
tf-plan            # review what will be created
tf-apply           # provision everything (~5 min)
```

`tf-bootstrap` is only needed once per AWS account. It creates the S3 bucket that stores Terraform state. After teardown and re-provisioning, run it again since the state bucket was also destroyed.

## What happens on the first `train` or `deploy`

The first cloud-mode command auto-orchestrates several steps:

1. Checks that the mutagen file sync session is running (starts it if not)
2. Opens the MLflow SSH tunnel (starts it if not)
3. Builds and pushes the container image if `devenv.nix` or `entrypoint.sh` changed
4. Submits the SageMaker job or updates the endpoint

You rarely need to run these sub-commands manually. They exist as escape hatches.

## EC2 instance size

Set in the wizard. Change it later:

```nix
# devenv.nix
env.TF_VAR_instance_type = "g4dn.xlarge";
```

Then `tf-apply` replaces the instance. MLflow data survives because the backup/restore cycle handles the transition — run `teardown` first if you want to save experiment history, or `nixos-rebuild` if the instance stays the same.

## SageMaker training quotas

New AWS accounts have **all SageMaker training instance quotas set to 0**. `train` will fail with a quota error until you request an increase:

1. Go to **Service Quotas** → **Amazon SageMaker** in the AWS console
2. Request an increase for the instance type you want (e.g. `ml.m5.large` for CPU training)
3. Approval takes minutes to a few hours

While waiting, use `train-on-ec2` instead — it runs on the EC2 VM directly without any quota.

## SageMaker public endpoint

By default the inference endpoint requires AWS authentication. To expose it publicly:

```nix
# devenv.nix
env.TF_VAR_sagemaker_public_endpoint = "true";
```

Then `tf-apply` and `deploy-status` will print the public HTTPS URL.

## Costs

Approximate monthly costs (us-east-1, on-demand):

| Resource           | Example                  | Cost/month  |
|--------------------|--------------------------|-------------|
| EC2                | `t3.small` (24/7)        | ~$15        |
| EC2                | `g4dn.xlarge` (24/7)     | ~$375       |
| S3                 | 50 GB data + state       | ~$1         |
| SageMaker endpoint | `ml.t2.medium` (24/7)    | ~$50        |
| SageMaker training | `ml.m5.large` per hour   | ~$0.12/hr   |

Stop the EC2 instance when not in use to reduce cost. MLflow data persists on the EBS volume.
