# Inference

## Overview

`deploy <run-id>` packages a trained model from MLflow and deploys it for inference.

```sh
deploy abc123def456
deploy abc123def456 artifacts/model    # custom artifact path within the run
```

In **local** mode, `deploy` starts `mlflow models serve` on `localhost:5001`.

In **cloud** mode, `deploy` builds a model package and updates (or creates) the SageMaker endpoint.

## The inference script

Edit `src/inference.py` to define how your model handles requests. It follows the MLflow pyfunc interface:

```python
def model_fn(model_dir):
    """Load the model from disk. Called once on container startup."""
    import joblib
    return joblib.load(f"{model_dir}/model.pkl")

def input_fn(request_body, content_type):
    """Parse the incoming request."""
    import json, numpy as np
    data = json.loads(request_body)
    return np.array(data["inputs"])

def predict_fn(input_data, model):
    """Run inference."""
    return model.predict(input_data)

def output_fn(prediction, accept):
    """Format the response."""
    import json
    return json.dumps(prediction.tolist()), "application/json"
```

Set the script path in `devenv.nix` (default is `src/inference.py`):

```nix
env.INFERENCE_SCRIPT = "src/inference.py";
```

## Cloud deploy flow

When you run `deploy <run-id>` in cloud mode:

1. Opens the MLflow SSH tunnel if not already open
2. Builds and pushes the container image if `devenv.nix` or `entrypoint.sh` changed
3. Downloads model artifacts from MLflow on EC2
4. Creates `model.tar.gz`:
   ```
   code/inference.py    ← your inference script
   <model files>        ← whatever mlflow.log_model() saved (pkl, pt, etc.)
   ```
5. Uploads the tarball to S3
6. Runs `tf-apply` to create or update the SageMaker endpoint

## Testing the endpoint

```sh
deploy-status          # show endpoint status + URL

# Local:
curl -X POST http://localhost:5001/invocations \
  -H 'Content-Type: application/json' \
  -d '{"inputs": [[1.0, 2.0, 3.0]]}'

# Cloud (requires AWS auth by default):
aws sagemaker-runtime invoke-endpoint \
  --endpoint-name nix-ml-solo-dev-endpoint \
  --content-type application/json \
  --body '{"inputs": [[1.0, 2.0, 3.0]]}' \
  /dev/stdout
```

## Public endpoint

By default the SageMaker endpoint requires AWS credentials. To expose it over HTTPS without authentication:

```nix
# devenv.nix
env.TF_VAR_sagemaker_public_endpoint = "true";
```

Then `tf-apply`. `deploy-status` will print the public URL after the next `deploy`.

## Dependency management

Your `src/inference.py` has access to everything in `pyproject.toml`. Dependencies are baked into the container image via `uv sync --frozen` at build time — the same `uv.lock` as your local environment. There is no `requirements.txt` needed in the model tarball.

## Endpoint scaling

The SageMaker endpoint autoscales between a minimum and maximum instance count. Configure in `devenv.nix`:

```nix
env.TF_VAR_endpoint_min_capacity = "0";   # scale to zero when idle
env.TF_VAR_endpoint_max_capacity = "2";
```

Scaling to zero eliminates idle cost but adds a cold-start delay (~2 min).
