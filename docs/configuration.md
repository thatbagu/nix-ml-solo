# Configuration

## `devenv.nix` is the single source of truth

All project-wide settings live in one place:

```nix
let
  project      = "nix-ml-solo";   # flows into all AWS resource names
  environment  = "dev";
  mlflowPort   = 5000;
  jupyterPort  = 8888;
  inferencePort = 5001;
in { ... }
```

Change a value here and it propagates automatically:

| Setting       | Where it appears                                                        |
|---------------|-------------------------------------------------------------------------|
| `project`     | EC2 name, S3 bucket names, ECR repo, mutagen session, SSH host alias   |
| `environment` | appended to every resource name (`<project>-<environment>-*`)           |
| `mlflowPort`  | MLflow server, SSH tunnel, `MLFLOW_TRACKING_URI`                        |
| `jupyterPort` | JupyterLab server and tunnel                                            |
| `inferencePort` | Local MLflow model server                                             |

## How settings reach Terraform

Nix sets `TF_VAR_*` environment variables in the shell. Terraform reads them automatically — no `-var-file` or `-var` flags needed.

```nix
env = {
  TF_VAR_project     = project;
  TF_VAR_environment = environment;
  # ...
};
```

This means `tofu plan` and `tofu apply` always use the values from `devenv.nix`.

## Switching modes

Comment or uncomment one line:

```nix
# local (default — no EC2 cost):
# env.INFRA_MODE = "cloud";

# cloud (EC2 + SageMaker):
env.INFRA_MODE = "cloud";
```

After changing, re-enter the shell (`exit` and `devenv shell` again) so the env var is picked up. No Terraform apply needed just to change the mode variable.

## Python dependencies

Managed by `uv` via `pyproject.toml`. Add a package:

```sh
uv add scikit-learn
```

This updates `uv.lock`. The same lock file is used locally, on EC2, and baked into the SageMaker container during `container-build`.

## Adding packages to the devenv environment

Tools available in the shell (and on EC2) come from `devenv.nix`:

```nix
packages = [
  pkgs.awscli2
  pkgs.git
  pkgs.curl
  pkgs.python312
  pkgs.htop        # add anything from nixpkgs here
];
```

After adding, run `direnv reload` to rebuild the shell. On EC2, run `nix-sync` followed by `nixos-rebuild` to push the updated closure.

## Changing ports

If a port is already in use, change it in `devenv.nix`:

```nix
mlflowPort = 5001;
```

Re-enter the shell. All scripts read the port from the environment variable, so the change propagates everywhere without editing individual scripts.

## Local wizard config

The wizard saves answers to `.devenv-configs/local.env`. This file is gitignored and contains:

```sh
AWS_AUTH_METHOD=iam
INFRA_MODE=cloud
TF_VAR_ssh_public_key=ssh-ed25519 AAAA...
SSH_IDENTITY_FILE=/home/you/.ssh/nix-ml-solo
```

Run `setup` to regenerate it from scratch.
