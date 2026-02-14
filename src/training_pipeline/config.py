#!/usr/bin/env python3
import os
import re
import json
import time
import random
import logging
import hashlib
from typing import Any, Dict, List, Optional, Tuple
from pydantic import BaseModel, Field, validator, root_validator

log = logging.getLogger("ml8s.config")
logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(message)s")

IDENTITY_VARS = [
    "DATA_ROOT",
    "TARGET_DATAFRAME",
    "TARGET_COLUMN",
    "TIME_COLUMN",
    "GROUP_COLUMN",
    "SAMPLE_ROWS",
    "TASK_TYPE",
    "TASK_SUBTYPE",
    "TEST_SIZE",
    "RANDOM_SEED",
    "FORECAST_HORIZON",
    "ENABLE_TIME_SPLIT",
    "ENABLE_RAY_TRANSFORMS",
    "ENABLE_FEATURETOOLS",
    "FT_TARGET_ENTITY",
    "FT_MAX_DEPTH",
    "FT_MAX_FEATURES",
    "FT_USE_TIME_INDEX",
    "MAX_FEATURES",
    "CORRELATION_THRESHOLD",
    "MAX_MISSING_RATIO",
    "ENABLE_LAG_FEATURES",
    "LAG_PERIODS",
    "ENABLE_ROLLING_FEATURES",
    "ROLLING_WINDOWS",
    "AUTOML_TIME_BUDGET",
    "MODEL_LIST",
    "HANDLE_IMBALANCE",
    "IMBALANCE_STRATEGY",
    "PRIMARY_METRIC",
    "RETRAIN_FROM_MODEL_URI",
    "MODEL_FORMAT",
    "SPLIT_STRATEGY",
    "TRAIN_SIZE",
    "CV_FOLDS",
    "STRATIFY_BY",
    "GROUP_SPLIT_COLUMN",
    "CANONICALIZATION_VERSION",
    "STRICT_DATA_FINGERPRINT"
]

PLATFORM_VARS = [
    "PIPELINE_ROOT_URI",
    "RAY_ADDRESS",
    "RAY_NUM_CPUS",
    "RAY_NUM_GPUS",
    "FE_PARALLELISM",
    "FE_BATCH_SIZE",
    "RAY_USE_STREAMING",
    "RAY_OBJECT_STORE_MEMORY",
    "FE_CPU_REQUEST",
    "FE_MEMORY_REQUEST",
    "TRAIN_CPU_REQUEST",
    "TRAIN_MEMORY_REQUEST",
    "TRAIN_GPU",
    "CACHE_ENABLED",
    "CACHE_VERSION",
    "FORCE_RERUN",
    "MAX_ROWS_FULL_LOAD",
    "MAX_FEATURE_CAP_PLATFORM",
    "MAX_AUTOML_TIME_BUDGET",
    "ENABLE_MLFLOW",
    "MLFLOW_TRACKING_URI",
    "MLFLOW_EXPERIMENT_PREFIX",
    "MLFLOW_MODEL_NAME",
    "TRAINING_STAGE_TIMEOUT_SECONDS",
    "TRAINING_PIPELINE_MAX_SECONDS",
    "PIPELINE_MODE",
    "EXISTING_MODEL_PATH",
    "DISTRIBUTED_TRAINING",
    "TRAINING_FRAMEWORK",
    "LOG_LEVEL",
    "REDACTED_ENV_KEYS",
    "ARTIFACT_RETENTION_DAYS",
    "TENANT_ID",
    "PROJECT_ID"
]

ALLOWED_TASK_TYPES = {"classification", "regression", "forecasting", "clustering", "ranking", "survival", "anomaly", "multi_label", "multi_output"}
ALLOWED_MODEL_FORMATS = {"joblib", "onnx"}

def _norm_scalar(v: Optional[str]) -> Any:
    if v is None:
        return None
    s = str(v).strip()
    if s == "":
        return None
    sl = s.lower()
    if sl in ("true", "false", "1", "0", "yes", "no"):
        return sl in ("true", "1", "yes")
    if re.fullmatch(r"^-?\d+$", s):
        try:
            return int(s)
        except Exception:
            pass
    if re.fullmatch(r"^-?\d+\.\d+$", s):
        try:
            return float(s)
        except Exception:
            pass
    if "," in s:
        items = [i.strip() for i in s.split(",") if i.strip() != ""]
        unique_sorted = sorted(list(dict.fromkeys(items)))
        return unique_sorted
    return s

def _retry(fn, attempts: int = 3, base_delay: float = 0.5, max_delay: float = 5.0):
    last = None
    for i in range(attempts):
        try:
            return fn()
        except Exception as e:
            last = e
            sleep = min(max_delay, base_delay * (2 ** i) + random.random() * 0.1)
            time.sleep(sleep)
    raise last

def _to_abs_file_uri(uri: Optional[str]) -> Optional[str]:
    if uri is None or uri == "":
        return uri
    u = str(uri)
    if u.startswith("file://"):
        p = u[len("file://"):]
        return "file://" + os.path.abspath(p)
    if u.startswith("/"):
        return "file://" + os.path.abspath(u)
    return u

def _is_hex32(s: str) -> bool:
    return bool(re.fullmatch(r"[0-9a-fA-F]{32}", s))

def _extract_etag_like(info: Dict[str, Any]) -> Optional[str]:
    if not isinstance(info, dict):
        return None
    for key in ("ETag", "etag", "etag_md5", "md5", "md5Hash", "hash", "Hash"):
        v = info.get(key)
        if not v:
            continue
        if isinstance(v, bytes):
            try:
                v = v.decode("utf-8", errors="ignore")
            except Exception:
                v = str(v)
        v = str(v)
        if _is_hex32(v):
            return v.lower()
        try:
            import base64
            b = base64.b64decode(v)
            if len(b) == 16:
                return hashlib.md5(b).hexdigest()
        except Exception:
            pass
    size = info.get("size") or info.get("Size") or info.get("length")
    if size is not None:
        try:
            return f"size:{int(size)}"
        except Exception:
            return f"size:{size}"
    return None

def _stream_sha256_of_path(fs, path, chunk_size: int = 8 * 1024 * 1024) -> str:
    h = hashlib.sha256()
    with fs.open(path, "rb") as fh:
        while True:
            chunk = fh.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()

def compute_data_fingerprint(data_root: str, prefer_etag: bool = True, attempts: int = 3) -> str:
    import fsspec
    if not data_root:
        raise RuntimeError("DATA_ROOT is required to compute data fingerprint")
    data_root = _to_abs_file_uri(data_root)
    fs, root = fsspec.core.url_to_fs(data_root)
    root = root.rstrip("/")
    def _list_files():
        try:
            return sorted([p for p in fs.find(root) if not str(p).endswith("/")])
        except Exception:
            try:
                entries = fs.ls(root, detail=True)
                files = []
                for e in entries:
                    if isinstance(e, dict) and e.get("type") == "directory":
                        try:
                            deeper = fs.find(e["name"])
                            files.extend(deeper)
                        except Exception:
                            pass
                    else:
                        name = e.get("name") or e.get("path") or e
                        files.append(name)
                return sorted([p for p in files if not str(p).endswith("/")])
            except Exception:
                if fs.exists(root):
                    return [root]
                return []
    files = _retry(_list_files, attempts=attempts)
    if not files:
        raise RuntimeError(f"No files discovered under DATA_ROOT={data_root}")
    tokens: List[str] = []
    for p in files:
        def _token_for_path():
            try:
                info = {}
                try:
                    info = fs.info(p)
                except Exception:
                    info = {}
                token = None
                if prefer_etag and isinstance(info, dict):
                    et = _extract_etag_like(info)
                    if et:
                        if et.startswith("size:"):
                            token = f"{p}:{et}"
                        else:
                            token = f"{p}:{et}:{info.get('size','')}"
                    else:
                        token = None
                if token is None:
                    digest = _stream_sha256_of_path(fs, p)
                    token = f"{p}:sha256:{digest}"
                return token
            except Exception as e:
                raise RuntimeError(f"Failed to tokenise file {p}: {e}")
        token = _retry(_token_for_path, attempts=attempts)
        tokens.append(token)
    concat = "|".join(tokens).encode("utf-8")
    return hashlib.sha256(concat).hexdigest()

def canonicalize_env(env_map: Dict[str, Any]) -> Dict[str, Any]:
    out: Dict[str, Any] = {}
    for k, v in env_map.items():
        if v is None:
            out[k] = None
            continue
        if isinstance(v, (list, tuple)):
            items = [str(x).strip() for x in v if str(x).strip() != ""]
            items = sorted(list(dict.fromkeys(items)))
            out[k] = items
            continue
        if isinstance(v, bool):
            out[k] = v
            continue
        s = v
        out[k] = _norm_scalar(s)
    return out

def canonical_json_str(obj: Dict[str, Any]) -> str:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True, ensure_ascii=False)

def compute_full_hash_and_run_id(canonical_json: str, data_fingerprint: Optional[str], include_data_fingerprint: Optional[bool] = None) -> Tuple[str, str]:
    if include_data_fingerprint is None:
        include_data_fingerprint = bool(os.environ.get("STRICT_DATA_FINGERPRINT") in ("1", "true", "True", True))
    if include_data_fingerprint:
        if not data_fingerprint:
            raise RuntimeError("Data fingerprint required but not provided")
        combined = (canonical_json + "\n" + data_fingerprint).encode("utf-8")
    else:
        combined = canonical_json.encode("utf-8")
    full = hashlib.sha256(combined).hexdigest()
    run_id = full[:12]
    return full, run_id

def derive_artifact_root(pipeline_root_uri: str, run_id: str) -> str:
    if not pipeline_root_uri:
        raise RuntimeError("PIPELINE_ROOT_URI is required to derive artifact root")
    pr = pipeline_root_uri.rstrip("/")
    return f"{pr}/ml8s_training_runs/{run_id}"

def _atomic_write_json(obj: Any, uri: str):
    import fsspec
    fs, path = fsspec.core.url_to_fs(uri)
    tmp = uri + ".tmp"
    data = json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False).encode("utf-8")
    parent = os.path.dirname(path)
    try:
        if hasattr(fs, "makedirs"):
            fs.makedirs(parent, exist_ok=True)
    except Exception:
        pass
    with fs.open(tmp, "wb") as fh:
        fh.write(data)
    try:
        if hasattr(fs, "rename"):
            fs.rename(tmp, uri)
            return uri
    except Exception:
        pass
    try:
        fs.copy(tmp, uri)
        fs.rm(tmp)
    except Exception:
        raise RuntimeError(f"Failed atomic write for {uri}")
    return uri

def persist_config_snapshot(artifact_root: str, canonical_cfg: Dict[str, Any], full_hash: str, run_id: str, data_fingerprint: Optional[str], redact_keys: Optional[List[str]] = None) -> str:
    snapshot = {
        "canonical_config": canonical_cfg,
        "full_config_hash": full_hash,
        "run_id": run_id,
        "data_fingerprint": data_fingerprint,
        "timestamp_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    }
    env_snapshot: Dict[str, Any] = {}
    redact_set = set([k.strip() for k in (os.environ.get("REDACTED_ENV_KEYS") or "").split(",") if k.strip()]) if redact_keys is None else set(redact_keys)
    for k in sorted(os.environ.keys()):
        if k in redact_set:
            env_snapshot[k] = "<REDACTED>"
        else:
            env_snapshot[k] = os.environ[k]
    snapshot["env"] = env_snapshot
    cfg_uri = artifact_root.rstrip("/") + "/config_snapshot.json"
    _atomic_write_json(snapshot, cfg_uri)
    log.info("Persisted config snapshot to %s", cfg_uri)
    return cfg_uri

class PlatformConfig(BaseModel):
    DATA_ROOT: str = Field(...)
    PIPELINE_ROOT_URI: str = Field(...)
    TASK_TYPE: str = Field("classification")
    TASK_SUBTYPE: Optional[str] = Field(None)
    TARGET_COLUMN: Optional[str] = Field(None)
    TARGET_DATAFRAME: Optional[str] = Field(None)
    ENABLE_TIME_SPLIT: bool = Field(False)
    TIME_COLUMN: Optional[str] = Field(None)
    GROUP_COLUMN: Optional[str] = Field(None)
    FORECAST_HORIZON: Optional[int] = Field(1)
    SAMPLE_ROWS: int = Field(0)
    STRICT_DATA_FINGERPRINT: bool = Field(True)
    CANONICALIZATION_VERSION: str = Field("1.0.0")
    RANDOM_SEED: int = Field(42)
    TASK_SUBTYPE_HINT: Optional[str] = Field(None)

    ENABLE_RAY_TRANSFORMS: bool = Field(True)
    RAY_ADDRESS: str = Field("local")
    RAY_NUM_CPUS: int = Field(4)
    RAY_NUM_GPUS: int = Field(0)
    FE_PARALLELISM: int = Field(8)
    FE_BATCH_SIZE: int = Field(50000)
    RAY_USE_STREAMING: Optional[bool] = Field(None)
    RAY_OBJECT_STORE_MEMORY: Optional[str] = Field(None)

    ENABLE_FEATURETOOLS: bool = Field(False)
    FT_TARGET_ENTITY: Optional[str] = Field(None)
    FT_MAX_DEPTH: Optional[int] = Field(2)
    FT_MAX_FEATURES: Optional[int] = Field(500)
    FT_USE_TIME_INDEX: bool = Field(True)

    MAX_FEATURES: int = Field(1000)
    CORRELATION_THRESHOLD: float = Field(0.95)
    MAX_MISSING_RATIO: float = Field(0.8)
    ENABLE_LAG_FEATURES: bool = Field(False)
    LAG_PERIODS: Optional[List[int]] = Field(None)
    ENABLE_ROLLING_FEATURES: bool = Field(False)
    ROLLING_WINDOWS: Optional[List[int]] = Field(None)

    SPLIT_STRATEGY: str = Field("auto")
    TRAIN_SIZE: float = Field(0.8)
    CV_FOLDS: int = Field(5)
    STRATIFY_BY: Optional[str] = Field(None)
    GROUP_SPLIT_COLUMN: Optional[str] = Field(None)

    AUTOML_TIME_BUDGET: int = Field(0)
    N_CONCURRENT_TRIALS: int = Field(1)
    MODEL_LIST: Optional[List[str]] = Field(None)
    HANDLE_IMBALANCE: bool = Field(False)
    IMBALANCE_STRATEGY: str = Field("auto")
    MAX_CLASS_IMBALANCE_RATIO: int = Field(10)
    MODEL_BACKEND: str = Field("sklearn")
    DISTRIBUTED_TRAINING: bool = Field(False)
    TRAINING_FRAMEWORK: str = Field("native")
    MODEL_FORMAT: str = Field("joblib")
    PRIMARY_METRIC: Optional[str] = Field(None)

    PIPELINE_MODE: str = Field("full")
    EXISTING_MODEL_PATH: Optional[str] = Field(None)

    FE_CPU_REQUEST: int = Field(4)
    FE_MEMORY_REQUEST: str = Field("8Gi")
    TRAIN_CPU_REQUEST: int = Field(8)
    TRAIN_MEMORY_REQUEST: str = Field("32Gi")
    TRAIN_GPU: int = Field(0)

    CACHE_ENABLED: bool = Field(True)
    CACHE_VERSION: str = Field("v1")
    FORCE_RERUN: bool = Field(False)

    MAX_ROWS_FULL_LOAD: int = Field(2000000)
    MAX_FEATURE_CAP_PLATFORM: int = Field(1000)
    MAX_AUTOML_TIME_BUDGET: int = Field(1800)

    ENABLE_MLFLOW: bool = Field(False)
    MLFLOW_TRACKING_URI: Optional[str] = Field(None)
    MLFLOW_EXPERIMENT_PREFIX: str = Field("ml8s_runs")
    MLFLOW_MODEL_NAME: Optional[str] = Field(None)

    TRAINING_STAGE_TIMEOUT_SECONDS: int = Field(3600)
    TRAINING_PIPELINE_MAX_SECONDS: int = Field(7200)

    GLOBAL_RANDOM_SEED: int = Field(42)
    DETERMINISTIC_TRAINING: bool = Field(True)

    MIN_ACCEPTABLE_METRIC: Optional[float] = Field(None)
    EARLY_STOPPING_ENABLED: bool = Field(True)
    EARLY_STOPPING_ROUNDS: int = Field(50)
    SAVE_OOF_PREDICTIONS: bool = Field(False)

    ENABLE_FEATURE_IMPORTANCE: bool = Field(True)
    ENABLE_SHAP_VALUES: bool = Field(False)
    MAX_SHAP_SAMPLES: int = Field(5000)
    EXPORT_BASELINE_STATISTICS: bool = Field(True)

    DRIFT_REFERENCE_WINDOW: str = Field("train")
    EXPORT_PIPELINE_METRICS: bool = Field(True)

    TENANT_ID: str = Field("default")
    PROJECT_ID: str = Field("default")

    PII_COLUMNS: Optional[List[str]] = Field(None)
    HASH_PII_COLUMNS: bool = Field(True)
    LOG_SAMPLE_ROWS: bool = Field(False)

    ARTIFACT_RETENTION_DAYS: int = Field(30)

    REDACTED_ENV_KEYS: Optional[str] = Field("AWS_SECRET_ACCESS_KEY,AZURE_CLIENT_SECRET,GOOGLE_APPLICATION_CREDENTIALS")
    LOG_LEVEL: str = Field("INFO")

    @validator("TASK_TYPE")
    def validate_task_type(cls, v: str) -> str:
        if v not in ALLOWED_TASK_TYPES:
            raise ValueError(f"TASK_TYPE must be one of {sorted(ALLOWED_TASK_TYPES)}")
        return v

    @validator("MODEL_FORMAT")
    def validate_model_format(cls, v: str) -> str:
        if v not in ALLOWED_MODEL_FORMATS:
            raise ValueError("MODEL_FORMAT must be 'joblib' or 'onnx'")
        return v

    @validator("TRAIN_SIZE")
    def check_train_size(cls, v: float) -> float:
        if not (0.0 < v < 1.0):
            raise ValueError("TRAIN_SIZE must be between 0 and 1")
        return v

    @validator("CV_FOLDS")
    def check_cv_folds(cls, v: int) -> int:
        if v < 0:
            raise ValueError("CV_FOLDS must be >= 0")
        return v

    @validator("LAG_PERIODS", pre=True)
    def parse_lag_periods(cls, v):
        if v is None or v == "":
            return None
        if isinstance(v, list):
            return [int(x) for x in v]
        if isinstance(v, str):
            return [int(x) for x in v.split(",") if x.strip().isdigit()]
        raise ValueError("LAG_PERIODS must be comma-separated ints or list")

    @validator("ROLLING_WINDOWS", pre=True)
    def parse_rolling_windows(cls, v):
        if v is None or v == "":
            return None
        if isinstance(v, list):
            return [int(x) for x in v]
        if isinstance(v, str):
            return [int(x) for x in v.split(",") if x.strip().isdigit()]
        raise ValueError("ROLLING_WINDOWS must be comma-separated ints or list")

    @root_validator
    def cross_field_checks(cls, values):
        tt = values.get("TASK_TYPE")
        tcol = values.get("TARGET_COLUMN")
        time_col = values.get("TIME_COLUMN")
        enable_time_split = values.get("ENABLE_TIME_SPLIT")
        fh = values.get("FORECAST_HORIZON")
        if tt in ("classification", "regression") and not tcol:
            raise ValueError("TARGET_COLUMN is required for supervised tasks")
        if tt == "forecasting":
            if not time_col and not enable_time_split:
                raise ValueError("forecasting requires TIME_COLUMN or ENABLE_TIME_SPLIT")
            if not fh or int(fh) <= 0:
                raise ValueError("FORECAST_HORIZON must be integer > 0 for forecasting")
        if values.get("DISTRIBUTED_TRAINING") and values.get("TRAINING_FRAMEWORK") != "ray_train":
            log.warning("DISTRIBUTED_TRAINING requested but TRAINING_FRAMEWORK is not 'ray_train'; override TRAINING_FRAMEWORK or set DISTRIBUTED_TRAINING=false")
        return values

    class Config:
        extra = "ignore"

def load_from_env(os_env: Optional[Dict[str, str]] = None) -> PlatformConfig:
    env = os_env or dict(os.environ)
    parsed: Dict[str, Any] = {}
    for field in PlatformConfig.__fields__.keys():
        raw = env.get(field)
        parsed[field] = _norm_scalar(raw)
    cfg = PlatformConfig.parse_obj(parsed)
    log.info("Loaded PlatformConfig task_type=%s pipeline_mode=%s run_seed=%s", cfg.TASK_TYPE, cfg.PIPELINE_MODE, cfg.GLOBAL_RANDOM_SEED)
    return cfg

def build_canonical_config(cfg: PlatformConfig) -> Dict[str, Any]:
    canonical_map: Dict[str, Any] = {}
    for k in IDENTITY_VARS:
        if hasattr(cfg, k):
            val = getattr(cfg, k)
            canonical_map[k] = val
    for k in list(canonical_map.keys()):
        v = canonical_map[k]
        if v is None or v == "":
            canonical_map[k] = None
        elif isinstance(v, list):
            canonical_map[k] = sorted(list(dict.fromkeys([str(x) for x in v])))
        elif isinstance(v, bool):
            canonical_map[k] = bool(v)
        else:
            canonical_map[k] = v
    return canonical_map

def canonical_json_and_hash(cfg: PlatformConfig, data_fingerprint: Optional[str]) -> Tuple[str, str, str]:
    canonical_cfg = build_canonical_config(cfg)
    canonical_json = canonical_json_str(canonical_cfg)
    full_hash, run_id = compute_full_hash_and_run_id(canonical_json, data_fingerprint, include_data_fingerprint=cfg.STRICT_DATA_FINGERPRINT)
    return canonical_json, full_hash, run_id

if __name__ == "__main__":
    try:
        config = load_from_env()
        data_fp = None
        try:
            data_fp = compute_data_fingerprint(config.DATA_ROOT)
            log.info("Computed DATA_FINGERPRINT=%s", data_fp)
        except Exception as e:
            log.error("Failed to compute DATA_FINGERPRINT: %s", e)
            raise
        canonical_json, full_hash, run_id = canonical_json_and_hash(config, data_fp)
        artifact_root = derive_artifact_root(config.PIPELINE_ROOT_URI, run_id)
        persist_config_snapshot(artifact_root, build_canonical_config(config), full_hash, run_id, data_fp)
        log.info("Bootstrap complete run_id=%s artifact_root=%s", run_id, artifact_root)
    except Exception as exc:
        log.exception("Bootstrap failed: %s", exc)
        raise
