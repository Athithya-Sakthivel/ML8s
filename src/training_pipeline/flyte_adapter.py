#!/usr/bin/env python3
from typing import Dict, Any
import os
import logging

log = logging.getLogger("ml8s.flyte_adapter")
log.setLevel(os.environ.get("LOG_LEVEL", "INFO"))
logging.basicConfig(level=log.level)

try:
    from flytekit import task, workflow, Resources
    FLYTE_AVAILABLE = True
except Exception:
    FLYTE_AVAILABLE = False

if FLYTE_AVAILABLE:

    @task(requests=Resources(cpu="1", mem="1Gi"))
    def flyte_bootstrap() -> Dict[str, str]:
        from config import load_from_env, compute_data_fingerprint, canonical_json_and_hash, derive_artifact_root, persist_config_snapshot
        import json
        cfg = load_from_env()
        data_fp = compute_data_fingerprint(cfg.DATA_ROOT)
        canonical_json, full_hash, run_id = canonical_json_and_hash(cfg, data_fp)
        artifact_root = derive_artifact_root(cfg.PIPELINE_ROOT_URI, run_id)
        persist_config_snapshot(artifact_root, json.loads(canonical_json), full_hash, run_id, data_fp)
        return {
            "canonical_json": canonical_json,
            "full_config_hash": full_hash,
            "run_id": run_id,
            "artifact_root": artifact_root,
            "data_fingerprint": data_fp,
        }

    @task(requests=Resources(cpu="0.5", mem="512Mi"))
    def flyte_idempotence(artifact_root: str, full_config_hash: str, data_fingerprint: str, force_rerun: bool) -> Dict[str, Any]:
        from config import check_existing_run_and_validate
        exists, reason = check_existing_run_and_validate(artifact_root, full_config_hash, data_fingerprint)
        if exists and not force_rerun:
            return {"early_exit": True, "reason": reason}
        if exists and force_rerun:
            try:
                import fsspec
                fs, path = fsspec.core.url_to_fs(artifact_root.rstrip("/") + "/success.marker")
                if fs.exists(path):
                    fs.rm(path)
            except Exception:
                log.warning("Could not remove success.marker during FORCE_RERUN; continuing")
        return {"early_exit": False}

    @task(requests=Resources(cpu="2", mem="4Gi"))
    def flyte_fe(artifact_root: str, run_id: str) -> Dict[str, str]:
        from preprocessing import run_preprocessing
        from config import load_from_env
        cfg = load_from_env()
        features_uri, meta = run_preprocessing(cfg=cfg, artifact_root=artifact_root, run_id=run_id)
        return {
            "features_uri": features_uri,
            "schema_uri": meta.get("schema_uri"),
            "manifest_uri": meta.get("manifest_uri"),
        }

    @task(requests=Resources(cpu="4", mem="8Gi"))
    def flyte_train(fe_info: Dict[str, str], boot: Dict[str, str]) -> Dict[str, Any]:
        from train import run_train_and_eval
        from config import load_from_env
        cfg = load_from_env()
        model_uri, meta = run_train_and_eval(
            features_uri=fe_info["features_uri"],
            feature_schema_uri=fe_info["schema_uri"],
            artifact_root=boot["artifact_root"],
            run_id=boot["run_id"],
            full_config_hash=boot["full_config_hash"],
            data_fingerprint=boot["data_fingerprint"],
            cfg=cfg,
        )
        return {"model_uri": model_uri, "train_meta": meta}

    @workflow
    def ml8s_workflow(force_rerun: bool = False) -> Dict[str, str]:
        boot = flyte_bootstrap()
        _ = flyte_idempotence(
            boot["artifact_root"],
            boot["full_config_hash"],
            boot["data_fingerprint"],
            force_rerun,
        )
        fe = flyte_fe(boot["artifact_root"], boot["run_id"])
        tr = flyte_train(fe, boot)
        return {
            "run_id": boot["run_id"],
            "artifact_root": boot["artifact_root"],
            "model_uri": tr["model_uri"],
        }

else:

    def ml8s_workflow(*args, **kwargs):
        raise ImportError("flytekit not available; install flytekit==1.16.13 to use Flyte adapters")
