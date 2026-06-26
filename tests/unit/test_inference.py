"""Tests for the SageMaker inference script contract."""

import json
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import numpy as np
import pytest

sys.path.insert(0, str(Path(__file__).parent.parent.parent / "src"))
import inference


class TestInputFn:
    def test_parses_valid_json(self):
        body = json.dumps({"instances": [[1.0, 2.0, 3.0]]})
        result = inference.input_fn(body, "application/json")
        assert result == {"instances": [[1.0, 2.0, 3.0]]}

    def test_rejects_unsupported_content_type(self):
        with pytest.raises(ValueError, match="Unsupported content type"):
            inference.input_fn("data", "text/plain")

    def test_defaults_to_json(self):
        body = json.dumps({"instances": [1]})
        result = inference.input_fn(body)
        assert result == {"instances": [1]}


class TestOutputFn:
    def test_serialises_list(self):
        body, content_type = inference.output_fn([0.1, 0.9], "application/json")
        assert content_type == "application/json"
        assert json.loads(body) == {"predictions": [0.1, 0.9]}

    def test_serialises_numpy_array(self):
        body, content_type = inference.output_fn(
            np.array([0.1, 0.9]), "application/json"
        )
        assert json.loads(body) == {"predictions": [0.1, 0.9]}

    def test_rejects_unsupported_accept_type(self):
        with pytest.raises(ValueError, match="Unsupported accept type"):
            inference.output_fn([1], "text/csv")

    def test_defaults_to_json(self):
        body, content_type = inference.output_fn([1])
        assert content_type == "application/json"


class TestPredictFn:
    def test_calls_model_predict(self):
        model = MagicMock()
        model.predict.return_value = [0, 1]
        result = inference.predict_fn({"instances": [[1, 2]]}, model)
        model.predict.assert_called_once_with({"instances": [[1, 2]]})
        assert result == [0, 1]


class TestModelFn:
    def test_loads_pyfunc_model(self, tmp_path):
        with patch("inference.mlflow.pyfunc.load_model") as mock_load:
            mock_load.return_value = MagicMock()
            inference.model_fn(str(tmp_path))
            mock_load.assert_called_once_with(str(tmp_path))

    def test_returns_loaded_model(self, tmp_path):
        fake_model = MagicMock()
        with patch("inference.mlflow.pyfunc.load_model", return_value=fake_model):
            result = inference.model_fn(str(tmp_path))
            assert result is fake_model
