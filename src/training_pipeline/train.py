#!/usr/bin/env python3
import os
import time
import json
import tempfile
import logging
from typing import Tuple, Dict, Any

import numpy as np

from config import PlatformConfig
from contracts import TrainingMetadata

import io as io_utils

log = logging.getLogger("ml8s.train")
log.setLevel(os.environ.get("LOG_LEVEL", "INFO"))


def _set_global_seed(seed: int):
    import random as _r
    import numpy as _np
    _r.seed(int(seed))
    _np.random.seed(int(seed))
    try:
        import torch
        torch.manual_seed(int(seed))
    except Exception:
        log.debug("torch not available or failed to seed")


def _read_features(features_uri: str):
    try:
        df = io_utils.read_parquet(features_uri)
        rows = getattr(df, "shape", (None,))[0] if hasattr(df, "shape") else None
        cols = getattr(df, "shape", (None, None))[1] if hasattr(df, "shape") else None
        log.info("Read features from %s rows=%s cols=%s", features_uri, rows, cols)
        return df
    except Exception as e:
        log.exception("Failed to read features from %s", features_uri)
        raise RuntimeError(f"Failed to read features from {features_uri}: {e}")


def _deterministic_split(df, cfg: PlatformConfig):
    if getattr(cfg, "ENABLE_TIME_SPLIT", False) and getattr(cfg, "TIME_COLUMN", None):
        if cfg.TIME_COLUMN not in df.columns:
            raise RuntimeError("ENABLE_TIME_SPLIT=true but TIME_COLUMN missing in features")
        sorted_df = df.sort_values(by=cfg.TIME_COLUMN).reset_index(drop=True)
        n = len(sorted_df)
        cut = int(n * float(cfg.TRAIN_SIZE))
        train = sorted_df.iloc[:cut].reset_index(drop=True)
        test = sorted_df.iloc[cut:].reset_index(drop=True)
        log.info("Performed time-based split train=%s test=%s", len(train), len(test))
        return train, test
    from sklearn.model_selection import train_test_split
    stratify_col = None
    if cfg.TASK_TYPE == "classification" and getattr(cfg, "STRATIFY_BY", None):
        if cfg.STRATIFY_BY in df.columns:
            stratify_col = df[cfg.STRATIFY_BY]
    seed = int(getattr(cfg, "GLOBAL_RANDOM_SEED", 42) or 42)
    try:
        train, test = train_test_split(df, train_size=float(cfg.TRAIN_SIZE), shuffle=True, random_state=seed, stratify=stratify_col)
    except Exception:
        train, test = train_test_split(df, train_size=float(cfg.TRAIN_SIZE), shuffle=True, random_state=seed)
    log.info("Performed random split train=%s test=%s seed=%s", len(train), len(test), seed)
    return train.reset_index(drop=True), test.reset_index(drop=True)


def _export_model_joblib(model, artifact_dir: str, run_id: str) -> str:
    import joblib
    local = tempfile.NamedTemporaryFile(delete=False, suffix=f".{run_id}.joblib")
    local.close()
    log.info("Dumping model with joblib to %s", local.name)
    filenames = joblib.dump(model, local.name)
    if isinstance(filenames, (list, tuple)) and filenames:
        saved_path = filenames[0]
    else:
        saved_path = local.name
    target = artifact_dir.rstrip("/") + f"/model_native_{run_id}.joblib"
    try:
        out = io_utils.upload_from_local(saved_path, target)
        log.info("Uploaded joblib model from %s -> %s", saved_path, out)
    finally:
        try:
            os.remove(local.name)
        except Exception:
            log.debug("Failed to remove temp file %s", local.name)
    return out


def _export_model_onnx(model, feature_schema_uri: str, artifact_dir: str, run_id: str) -> str:
    try:
        from skl2onnx import convert_sklearn
        from skl2onnx.common.data_types import FloatTensorType
    except Exception as e:
        log.exception("skl2onnx import failed")
        raise RuntimeError(f"ONNX conversion dependencies missing: {e}")
    try:
        fs, path = io_utils.url_to_fs(feature_schema_uri)
        with fs.open(path, "rb") as fh:
            schema = json.loads(fh.read().decode("utf-8"))
        columns = [c["name"] for c in schema.get("columns", [])]
        if not columns:
            raise RuntimeError("Feature schema contains no columns")
        init = [("input", FloatTensorType([None, len(columns)]))]
        log.info("Converting model to ONNX with %d features", len(columns))
        onx = convert_sklearn(model, initial_types=init)
        tmp = artifact_dir.rstrip("/") + f"/model_{run_id}.onnx.tmp"
        fs2, p2 = io_utils.url_to_fs(tmp)
        with fs2.open(p2, "wb") as fh:
            fh.write(onx.SerializeToString())
        final = artifact_dir.rstrip("/") + f"/model_{run_id}.onnx"
        io_utils.copy_uri(tmp, final)
        try:
            fs2.rm(p2)
        except Exception:
            log.debug("Failed to remove temporary onnx object %s", tmp)
        log.info("ONNX model stored at %s", final)
        return final
    except Exception as e:
        log.exception("ONNX export failed")
        raise RuntimeError(f"ONNX export failed: {e}")


def _mlflow_register(model_uri: str, run_id: str, full_config_hash: str, data_fingerprint: str, cfg: PlatformConfig) -> Dict[str, Any]:
    if not getattr(cfg, "ENABLE_MLFLOW", False):
        log.debug("MLflow disabled in config")
        return {}
    try:
        import mlflow
        mlflow_tracking_uri = getattr(cfg, "MLFLOW_TRACKING_URI", None) or os.environ.get("MLFLOW_TRACKING_URI")
        if mlflow_tracking_uri:
            mlflow.set_tracking_uri(mlflow_tracking_uri)
            log.info("Set MLflow tracking URI to %s", mlflow_tracking_uri)
        exp_prefix = getattr(cfg, "MLFLOW_EXPERIMENT_PREFIX", None) or "ml8s_runs"
        mlflow.set_experiment(exp_prefix)
        with mlflow.start_run(run_name=run_id) as run:
            mlflow.set_tag("run_id", run_id)
            mlflow.set_tag("full_config_hash", full_config_hash)
            mlflow.set_tag("data_fingerprint", data_fingerprint)
            mlflow.log_param("task_type", cfg.TASK_TYPE)
            mlflow.log_param("model_format", getattr(cfg, "MODEL_FORMAT", None))
            try:
                if str(model_uri).startswith("file://"):
                    local_path = model_uri.replace("file://", "")
                    if os.path.exists(local_path):
                        mlflow.log_artifact(local_path, artifact_path="model")
                    else:
                        tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
                        tmp.close()
                        with open(tmp.name, "w") as fh:
                            json.dump({"model_uri": model_uri}, fh)
                        mlflow.log_artifact(tmp.name, artifact_path="model")
                        try:
                            os.remove(tmp.name)
                        except Exception:
                            log.debug("Failed to remove temp mlflow json %s", tmp.name)
                else:
                    tmp = tempfile.NamedTemporaryFile(delete=False, suffix=".json")
                    tmp.close()
                    with open(tmp.name, "w") as fh:
                        json.dump({"model_uri": model_uri}, fh)
                    mlflow.log_artifact(tmp.name, artifact_path="model")
                    try:
                        os.remove(tmp.name)
                    except Exception:
                        log.debug("Failed to remove temp mlflow json %s", tmp.name)
            except Exception:
                log.exception("Failed to log model artifact to MLflow")
        log.info("MLflow registered run %s under experiment %s", run.info.run_id, exp_prefix)
        return {"mlflow_experiment": exp_prefix, "mlflow_run": run.info.run_id}
    except Exception as e:
        log.warning("MLflow logging failed: %s", e)
        return {}


def run_train_and_eval(features_uri: str, feature_schema_uri: str, artifact_root: str, run_id: str, full_config_hash: str, data_fingerprint: str, cfg: PlatformConfig) -> Tuple[str, Dict[str, Any]]:
    start = time.time()
    _set_global_seed(int(getattr(cfg, "GLOBAL_RANDOM_SEED", 42) or 42))
    df = _read_features(features_uri)
    if df is None or len(df) == 0:
        raise RuntimeError("Empty feature matrix")
    if not getattr(cfg, "TARGET_COLUMN", None) and cfg.TASK_TYPE in ("classification", "regression"):
        raise RuntimeError("TARGET_COLUMN must be set for supervised training")
    target_col = cfg.TARGET_COLUMN
    if target_col not in df.columns:
        raise RuntimeError(f"TARGET_COLUMN {target_col} missing in feature matrix")
    train_df, test_df = _deterministic_split(df, cfg)
    y_train = train_df[target_col]
    X_train = train_df.drop(columns=[target_col])
    y_test = test_df[target_col]
    X_test = test_df.drop(columns=[target_col])
    trained_model = None
    metrics: Dict[str, Any] = {}
    metadata = TrainingMetadata(run_id=run_id, full_config_hash=full_config_hash, data_fingerprint=data_fingerprint, backend=None, hyperparameters={}, timestamp_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    if getattr(cfg, "AUTOML_TIME_BUDGET", None) and int(getattr(cfg, "AUTOML_TIME_BUDGET", 0)) > 0:
        try:
            from flaml import AutoML
            automl = AutoML()
            automl_settings = {
                "time_budget": int(cfg.AUTOML_TIME_BUDGET),
                "metric": getattr(cfg, "PRIMARY_METRIC", None),
                "task": "classification" if cfg.TASK_TYPE == "classification" else "regression",
                "seed": int(getattr(cfg, "GLOBAL_RANDOM_SEED", 42) or 42)
            }
            if getattr(cfg, "MODEL_LIST", None):
                automl_settings["estimator_list"] = cfg.MODEL_LIST
            automl.fit(X_train=X_train, y_train=y_train, **automl_settings)
            trained_model = automl.model if hasattr(automl, "model") else automl
            metadata.backend = "flaml"
            try:
                preds = automl.predict(X_test)
                metrics["n_rows_test"] = int(len(y_test))
                if cfg.TASK_TYPE == "classification":
                    from sklearn.metrics import accuracy_score, roc_auc_score
                    metrics["accuracy"] = float(accuracy_score(y_test, preds))
                    try:
                        probs = automl.predict_proba(X_test)
                        if hasattr(probs, "shape") and probs.shape[1] > 1:
                            probs = probs[:, 1]
                        metrics["roc_auc"] = float(roc_auc_score(y_test, probs))
                    except Exception:
                        log.debug("FLAML predict_proba unavailable or failed")
                else:
                    from sklearn.metrics import mean_squared_error
                    metrics["rmse"] = float(mean_squared_error(y_test, preds, squared=False))
            except Exception:
                log.exception("Evaluation after FLAML failed")
        except Exception:
            log.exception("FLAML unavailable or failed; falling back to classic training")
            trained_model = None
    if trained_model is None:
        if getattr(cfg, "MODEL_BACKEND", None) and str(cfg.MODEL_BACKEND).lower() == "lightgbm":
            try:
                import lightgbm as lgb
                params = {"random_state": int(getattr(cfg, "GLOBAL_RANDOM_SEED", 42) or 42), "n_jobs": -1}
                if cfg.TASK_TYPE == "classification":
                    params["objective"] = "binary"
                    params["metric"] = "binary_logloss"
                else:
                    params["objective"] = "regression"
                    params["metric"] = "l2"
                dtrain = lgb.Dataset(X_train, label=y_train)
                dval = lgb.Dataset(X_test, label=y_test, reference=dtrain)
                num_round = int(getattr(cfg, "NUM_ROUNDS", 100) or 100)
                callbacks = []
                if getattr(cfg, "EARLY_STOPPING_ENABLED", False):
                    try:
                        callbacks.append(lgb.early_stopping(stopping_rounds=int(getattr(cfg, "EARLY_STOPPING_ROUNDS", 50) or 50)))
                    except Exception:
                        log.debug("failed to create early stopping callback")
                bst = lgb.train(params, dtrain, num_boost_round=num_round, valid_sets=[dval], callbacks=callbacks)
                trained_model = bst
                metadata.backend = "lightgbm"
                if cfg.TASK_TYPE == "classification":
                    preds_proba = bst.predict(X_test)
                    preds = (preds_proba > 0.5).astype(int)
                    from sklearn.metrics import accuracy_score
                    metrics["accuracy"] = float(accuracy_score(y_test, preds))
                else:
                    preds = bst.predict(X_test)
                    from sklearn.metrics import mean_squared_error
                    metrics["rmse"] = float(mean_squared_error(y_test, preds, squared=False))
            except Exception as e:
                log.exception("LightGBM training failed")
                raise RuntimeError(f"LightGBM training failed: {e}")
        else:
            from sklearn.pipeline import Pipeline
            from sklearn.impute import SimpleImputer
            from sklearn.preprocessing import StandardScaler
            from sklearn.linear_model import LogisticRegression
            from sklearn.ensemble import RandomForestClassifier, RandomForestRegressor
            est = None
            if cfg.TASK_TYPE == "classification":
                if getattr(cfg, "MODEL_LIST", None) and "rf" in (cfg.MODEL_LIST or []):
                    est = RandomForestClassifier(n_estimators=100, random_state=int(getattr(cfg, "GLOBAL_RANDOM_SEED", 42) or 42), class_weight='balanced' if getattr(cfg, "HANDLE_IMBALANCE", False) else None, n_jobs=-1)
                else:
                    est = LogisticRegression(max_iter=2000, random_state=int(getattr(cfg, "GLOBAL_RANDOM_SEED", 42) or 42))
            else:
                est = RandomForestRegressor(n_estimators=100, random_state=int(getattr(cfg, "GLOBAL_RANDOM_SEED", 42) or 42), n_jobs=-1)
            pipe = Pipeline([("imputer", SimpleImputer(strategy="median")), ("scaler", StandardScaler()), ("est", est)])
            pipe.fit(X_train, y_train)
            trained_model = pipe
            metadata.backend = "sklearn"
            preds = pipe.predict(X_test)
            if cfg.TASK_TYPE == "classification":
                from sklearn.metrics import accuracy_score, roc_auc_score
                metrics["accuracy"] = float(accuracy_score(y_test, preds))
                try:
                    probs = pipe.predict_proba(X_test)[:, 1]
                    metrics["roc_auc"] = float(roc_auc_score(y_test, probs))
                except Exception:
                    log.debug("predict_proba unavailable for estimator")
            else:
                from sklearn.metrics import mean_squared_error
                metrics["rmse"] = float(mean_squared_error(y_test, preds, squared=False))
    model_dir = artifact_root.rstrip("/") + "/model"
    try:
        if getattr(cfg, "MODEL_FORMAT", None) == "onnx":
            try:
                exported = _export_model_onnx(trained_model, feature_schema_uri, model_dir, run_id)
            except Exception as e:
                log.warning("ONNX export failed; falling back to joblib: %s", e)
                exported = _export_model_joblib(trained_model, model_dir, run_id)
                try:
                    if hasattr(metadata, "extra"):
                        metadata.extra["onnx_conversion_error"] = str(e)
                except Exception:
                    metadata.extra = {"onnx_conversion_error": str(e)}
        else:
            exported = _export_model_joblib(trained_model, model_dir, run_id)
    except Exception as e:
        log.exception("Model export failed")
        raise RuntimeError(f"Model export failed: {e}")
    model_sha = None
    try:
        if io_utils.exists(exported):
            model_sha = io_utils.compute_sha256_of_uri(exported)
            if hasattr(metadata, "record_model_bytes"):
                try:
                    metadata.record_model_bytes(exported)
                except Exception:
                    log.debug("record_model_bytes failed")
        log.info("Exported model URI %s sha256=%s", exported, model_sha)
    except Exception:
        model_sha = None
    metrics_uri = artifact_root.rstrip("/") + "/metrics.json"
    meta_uri = artifact_root.rstrip("/") + "/training_metadata.json"
    try:
        io_utils.atomic_write_json(metrics, metrics_uri)
        metadata.elapsed_seconds = time.time() - start
        metadata.model_sha256 = model_sha
        io_utils.atomic_write_json(metadata.dict(), meta_uri)
        log.info("Wrote metrics and metadata")
    except Exception:
        log.exception("Failed to persist metrics/metadata")
    mlflow_info = _mlflow_register(exported, run_id, full_config_hash, data_fingerprint, cfg)
    return exported, {"metrics": metrics, "metadata": metadata.dict(), "mlflow": mlflow_info}
