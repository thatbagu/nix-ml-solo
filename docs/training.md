# Training

## Basic usage

```sh
train src/train.py
train notebooks/experiment.ipynb
train src/train.py -- --epochs 10 --lr 0.001
train notebooks/experiment.ipynb -- -p lr 0.001 -p epochs 10
```

Arguments after `--` are passed to the script (Python) or to papermill (notebooks).

## How `train` routes the job

```
train <script>
    │
    ├── INFRA_MODE=local  →  python script.py  (or papermill for .ipynb)
    │                        MLflow → localhost:5000
    │
    └── INFRA_MODE=cloud  →  ensures sync is running
                          →  ensures MLflow tunnel is open
                          →  builds/pushes container if changed
                          →  submits SageMaker training job
                             MLflow → EC2 via tunnel
```

The cloud path is fully automatic. You don't need to run `sync`, `mlflow-open`, or `container-build` separately.

## Local training

Runs directly in the devenv shell:

```sh
train src/train.py
```

Equivalent to `uv run python src/train.py` with all devenv environment variables active. MLflow logs go to `./mlruns` and `./mlflow.db`.

## SageMaker training

Submits a training job using the container image in ECR:

```sh
train src/train.py -- --epochs 50
```

The job inherits the same environment variables (`MLFLOW_TRACKING_URI`, `DVC_REMOTE_URL`, etc.) so your script needs no changes between local and cloud.

Monitor the job:

```sh
train-status              # list recent jobs
train-status <job-name>   # describe a specific job
logs <job-name>           # stream CloudWatch logs
```

### SageMaker training instance type

```nix
# devenv.nix
env.TF_VAR_training_instance_type = "ml.g4dn.xlarge";
```

New AWS accounts have all training instance quotas at zero. Use `train-on-ec2` until you receive a quota increase.

## Training on EC2

Runs the script directly on the EC2 instance via SSH:

```sh
train-on-ec2 src/train.py
train-on-ec2 src/train.py -- --epochs 10
```

The script runs inside the devenv shell on EC2, so the environment is identical to local. No container build needed, no SageMaker quota required. Good for:

- Testing before requesting SageMaker quotas
- Long-running jobs where you want direct SSH access
- Workloads that don't fit the SageMaker container format

## Notebooks

`train` handles `.ipynb` files via [papermill](https://papermill.readthedocs.io/):

```sh
train notebooks/experiment.ipynb
train notebooks/experiment.ipynb -- -p learning_rate 0.01 -p batch_size 32
```

Papermill executes the notebook and saves an output copy with cell outputs filled in. Parameters are injected into the cell tagged `parameters` in your notebook.

## Setting a default training script

To avoid typing the path every time:

```nix
# devenv.nix
env.TRAINING_SCRIPT = "src/train.py";
```

Then `train` with no arguments uses this script.

## MLflow logging

The `MLFLOW_TRACKING_URI` environment variable is set automatically. In your script:

```python
import mlflow

mlflow.set_experiment("my-experiment")

with mlflow.start_run():
    mlflow.log_param("lr", 0.001)
    mlflow.log_metric("loss", 0.42)
    mlflow.sklearn.log_model(model, "model")
```

No URI configuration needed. The same code works in local and cloud mode.
