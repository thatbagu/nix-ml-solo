# Local Mode

Local mode runs everything on your laptop. No EC2 instance, no SageMaker — just S3 for DVC remote storage.

## When to use it

- During initial development when you don't need GPU
- To iterate quickly without waiting for SageMaker job queues
- To test your training script before submitting to SageMaker
- When you want zero AWS cost beyond S3 (~$0 for small datasets)

## What runs where

| Component  | Local mode                                     |
|------------|------------------------------------------------|
| MLflow     | `mlflow server` on `localhost:5000`            |
| Training   | `python script.py` directly in devenv shell    |
| Jupyter    | `jupyter lab` on `localhost:8888`              |
| Inference  | `mlflow models serve` on `localhost:5001`      |
| DVC remote | S3 (still uses AWS — only for data versioning) |

## Workflow

```sh
devenv shell          # or: direnv allow

mlflow-start          # start MLflow tracking server (background)
jupyter               # open JupyterLab

train src/train.py    # run training, logged to local MLflow
deploy <run-id>       # serve model locally

status                # show what's running
```

## Starting MLflow

`mlflow-start` runs the server in the foreground. Run it in a separate terminal or background it:

```sh
mlflow-start &
```

MLflow stores the database at `mlflow.db` and artifacts at `./mlruns` in the project root. Both are gitignored.

## Training

`train <script>` in local mode is equivalent to:

```sh
python script.py
# or for notebooks:
uv run papermill notebook.ipynb notebook-output.ipynb
```

All environment variables from `devenv.nix` (`MLFLOW_TRACKING_URI`, etc.) are already set, so MLflow logging works without any configuration in your script.

## Local inference

After training:

```sh
deploy <mlflow-run-id>
```

In local mode, `deploy` starts `mlflow models serve` using `src/inference.py`. The server listens at `localhost:5001`. Test it:

```sh
curl -X POST http://localhost:5001/invocations \
  -H 'Content-Type: application/json' \
  -d '{"inputs": [[1.0, 2.0, 3.0]]}'
```

## Switching to cloud

Once your script runs correctly locally:

1. Uncomment `env.INFRA_MODE = "cloud";` in `devenv.nix`
2. Re-enter the shell
3. Run `setup` if you haven't provisioned infrastructure yet
4. `train src/train.py` now submits a SageMaker job
