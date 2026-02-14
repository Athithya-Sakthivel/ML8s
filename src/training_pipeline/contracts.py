#!/usr/bin/env python3
from typing import List, Dict, Optional, Any
from pydantic import BaseModel, Field, validator, root_validator
import logging
import json
import time
import fsspec
import hashlib

log = logging.getLogger("ml8s.contracts")
log.setLevel(logging.INFO)

def _now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

class FeatureColumn(BaseModel):
    name: str
    dtype: str
    nullable: bool = True
    description: Optional[str] = None

    @validator("name")
    def name_non_empty(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("column name must be non-empty")
        return v.strip()

class FeatureSchema(BaseModel):
    columns: List[FeatureColumn] = Field(default_factory=list)
    num_rows: int = 0
    num_columns: int = 0
    dropped_by_corr: List[str] = Field(default_factory=list)
    dropped_by_max: List[str] = Field(default_factory=list)
    generated_ts: str = Field(default_factory=_now_iso)

    @root_validator
    def sync_counts(cls, values):
        cols = values.get("columns") or []
        values["num_columns"] = len(cols)
        if values.get("num_rows") is None:
            values["num_rows"] = 0
        return values

class TableFileToken(BaseModel):
    path: str
    token: str
    size: Optional[int] = None

class TableManifest(BaseModel):
    files: Dict[str, TableFileToken] = Field(default_factory=dict)
    table_fingerprint: str
    generated_ts: str = Field(default_factory=_now_iso)

    @validator("table_fingerprint")
    def fingerprint_len(cls, v: str) -> str:
        if not v or len(v) < 6:
            raise ValueError("table_fingerprint appears invalid")
        return v

class FeatureOutput(BaseModel):
    run_id: str
    features_uri: str
    schema: FeatureSchema
    num_rows: int
    num_columns: int
    data_fingerprint: Optional[str] = None
    table_manifests: Dict[str, TableManifest] = Field(default_factory=dict)
    metadata: Dict[str, Any] = Field(default_factory=dict)

    @root_validator
    def validate_counts(cls, values):
        schema = values.get("schema")
        if schema:
            values["num_rows"] = int(schema.num_rows or values.get("num_rows", 0))
            values["num_columns"] = int(schema.num_columns or values.get("num_columns", 0))
        return values

    def to_dict(self) -> Dict[str, Any]:
        return self.dict()

    def save_json(self, uri: str) -> str:
        fs, path = fsspec.core.url_to_fs(uri)
        data = json.dumps(self.to_dict(), indent=2, sort_keys=True, ensure_ascii=False).encode("utf-8")
        tmp = uri + ".tmp"
        with fs.open(tmp, "wb") as fh:
            fh.write(data)
        try:
            if hasattr(fs, "rename"):
                fs.rename(tmp, uri)
            else:
                fs.copy(tmp, uri); fs.rm(tmp)
        except Exception as e:
            log.error("Failed atomic save for %s: %s", uri, e)
            raise
        log.info("Saved FeatureOutput manifest to %s", uri)
        return uri

    @classmethod
    def load_json(cls, uri: str) -> "FeatureOutput":
        fs, path = fsspec.core.url_to_fs(uri)
        with fs.open(path, "rb") as fh:
            payload = json.loads(fh.read().decode("utf-8"))
        obj = cls.parse_obj(payload)
        log.info("Loaded FeatureOutput from %s", uri)
        return obj

class SplitIndices(BaseModel):
    train_uri: Optional[str] = None
    validation_uri: Optional[str] = None
    test_uri: Optional[str] = None
    train_count: int = 0
    validation_count: int = 0
    test_count: int = 0

class TrainingMetadata(BaseModel):
    run_id: str
    full_config_hash: Optional[str] = None
    data_fingerprint: Optional[str] = None
    backend: Optional[str] = None
    hyperparameters: Dict[str, Any] = Field(default_factory=dict)
    model_sha256: Optional[str] = None
    model_size_bytes: Optional[int] = None
    elapsed_seconds: Optional[float] = None
    timestamp_utc: str = Field(default_factory=_now_iso)
    extra: Dict[str, Any] = Field(default_factory=dict)

    def record_model_bytes(self, fs_uri: str) -> None:
        try:
            fs, p = fsspec.core.url_to_fs(fs_uri)
            with fs.open(p, "rb") as fh:
                data = fh.read()
            self.model_sha256 = hashlib.sha256(data).hexdigest()
            self.model_size_bytes = len(data)
            log.info("Recorded model checksum %s size %d for %s", self.model_sha256, self.model_size_bytes, fs_uri)
        except Exception as e:
            log.warning("Could not compute model bytes for %s: %s", fs_uri, e)

class ModelOutput(BaseModel):
    run_id: str
    artifact_root: str
    native_model_uri: str
    exported_model_uri: Optional[str] = None
    model_format: str = "joblib"
    training_metadata: TrainingMetadata
    validation_metrics: Dict[str, Any] = Field(default_factory=dict)
    export_validated: bool = False

    @validator("model_format")
    def allowed_formats(cls, v: str) -> str:
        if v not in ("joblib", "onnx"):
            raise ValueError("model_format must be 'joblib' or 'onnx'")
        return v

    def to_dict(self) -> Dict[str, Any]:
        return self.dict()

    def save_json(self, uri: str) -> str:
        fs, path = fsspec.core.url_to_fs(uri)
        data = json.dumps(self.to_dict(), indent=2, sort_keys=True, ensure_ascii=False).encode("utf-8")
        tmp = uri + ".tmp"
        with fs.open(tmp, "wb") as fh:
            fh.write(data)
        try:
            if hasattr(fs, "rename"):
                fs.rename(tmp, uri)
            else:
                fs.copy(tmp, uri); fs.rm(tmp)
        except Exception as e:
            log.error("Failed saving ModelOutput to %s: %s", uri, e)
            raise
        log.info("Saved ModelOutput manifest to %s", uri)
        return uri

    @classmethod
    def load_json(cls, uri: str) -> "ModelOutput":
        fs, path = fsspec.core.url_to_fs(uri)
        with fs.open(path, "rb") as fh:
            payload = json.loads(fh.read().decode("utf-8"))
        obj = cls.parse_obj(payload)
        log.info("Loaded ModelOutput from %s", uri)
        return obj

class PipelineResult(BaseModel):
    run_id: str
    artifact_root: str
    feature_output: Optional[FeatureOutput] = None
    split_indices: Optional[SplitIndices] = None
    model_output: Optional[ModelOutput] = None
    success: bool = False
    errors: List[str] = Field(default_factory=list)
    timestamps: Dict[str, str] = Field(default_factory=lambda: {"started": _now_iso(), "finished": ""})

    def mark_finished(self, success: bool = True) -> None:
        self.success = success
        self.timestamps["finished"] = _now_iso()
        log.info("PipelineResult finished=%s run_id=%s", success, self.run_id)

    def save_json(self, uri: str) -> str:
        fs, path = fsspec.core.url_to_fs(uri)
        data = json.dumps(self.dict(), indent=2, sort_keys=True, ensure_ascii=False).encode("utf-8")
        tmp = uri + ".tmp"
        with fs.open(tmp, "wb") as fh:
            fh.write(data)
        try:
            if hasattr(fs, "rename"):
                fs.rename(tmp, uri)
            else:
                fs.copy(tmp, uri); fs.rm(tmp)
        except Exception as e:
            log.error("Failed saving PipelineResult to %s: %s", uri, e)
            raise
        log.info("Saved PipelineResult manifest to %s", uri)
        return uri
