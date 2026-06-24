"""
SageMaker inference script template.

Copy to your project (e.g. src/inference.py) and set in devenv.nix:
    env.INFERENCE_SCRIPT = "src/inference.py";

SageMaker calls these four functions. model_fn is required; the rest
have sensible defaults but you'll almost always want to override them.

At runtime, model files are at /opt/ml/model/ (extracted from model.tar.gz).
This script is at /opt/ml/model/code/inference.py.
"""

import os
import json
import mlflow.pyfunc


# ── Required ──────────────────────────────────────────────────────────────────


def model_fn(model_dir: str):
    """Load the model from model_dir. Called once at container startup."""
    # MLflow logs a pyfunc-compatible model by default.
    # If you logged a flavour-specific model (sklearn, pytorch, etc.)
    # swap mlflow.pyfunc for e.g. mlflow.sklearn or mlflow.pytorch.
    return mlflow.pyfunc.load_model(model_dir)


# ── Optional — override to customise input/output format ─────────────────────


def input_fn(request_body: str, content_type: str = "application/json"):
    """Deserialise the request body into model input."""
    if content_type == "application/json":
        data = json.loads(request_body)
        # MLflow pyfunc expects a dict with 'dataframe_split' or 'instances'.
        # Adjust to match what your model expects.
        return data
    raise ValueError(f"Unsupported content type: {content_type}")


def predict_fn(input_data, model):
    """Run the model. Return raw predictions."""
    return model.predict(input_data)


def output_fn(prediction, accept: str = "application/json"):
    """Serialise predictions into the response body."""
    if accept == "application/json":
        if hasattr(prediction, "tolist"):
            prediction = prediction.tolist()
        return json.dumps({"predictions": prediction}), accept
    raise ValueError(f"Unsupported accept type: {accept}")
