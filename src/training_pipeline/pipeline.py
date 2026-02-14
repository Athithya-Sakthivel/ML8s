from typing import Dict, Any
import os
import sys
import json
import logging

log = logging.getLogger("ml8s.pipeline")
log.setLevel(os.environ.get("LOG_LEVEL", "INFO"))
logging.basicConfig(level=log.level)

def bootstrap_and_hash() -> Dict[str, str]:
    from config import load_from_env, compute_data_fingerprint, canonical_json_and_hash, derive_artifact_root, persist_config_snapshot
    cfg = load_from_env()
    if cfg.DATA_ROOT and cfg.DATA_ROOT.startswith("/"):
        cfg.DATA_ROOT = "file://" + os.path.abspath(cfg.DATA_ROOT)
    if cfg.PIPELINE_ROOT_URI and cfg.PIPELINE_ROOT_URI.startswith("/"):
        cfg.PIPELINE_ROOT_URI = "file://" + os.path.abspath(cfg.PIPELINE_ROOT_URI)
    data_fp = compute_data_fingerprint(cfg.DATA_ROOT)
    canonical_json, full_hash, run_id = canonical_json_and_hash(cfg, data_fp)
    artifact_root = derive_artifact_root(cfg.PIPELINE_ROOT_URI, run_id)
    persist_config_snapshot(artifact_root, json.loads(canonical_json), full_hash, run_id, data_fp)
    os.environ["FULL_CONFIG_HASH"] = full_hash
    os.environ["RUN_ID"] = run_id
    os.environ["ARTIFACT_ROOT"] = artifact_root
    log.info("bootstrap complete run_id=%s artifact_root=%s", run_id, artifact_root)
    return {
        "canonical_config": json.loads(canonical_json),
        "canonical_json": canonical_json,
        "data_fingerprint": data_fp,
        "full_config_hash": full_hash,
        "run_id": run_id,
        "artifact_root": artifact_root,
    }

def idempotence_gate(artifact_root: str, expected_full_hash: str, expected_data_fingerprint: str, force_rerun: bool = False) -> Dict[str, Any]:
    from config import check_existing_run_and_validate
    exists, status = check_existing_run_and_validate(artifact_root, expected_full_hash, expected_data_fingerprint)
    if exists and not force_rerun:
        log.info("Existing valid run detected at %s (%s). Early exit.", artifact_root, status)
        return {"early_exit": True, "reason": status}
    if exists and force_rerun:
        try:
            import fsspec
            fs, path = fsspec.core.url_to_fs(artifact_root.rstrip("/") + "/success.marker")
            if fs.exists(path):
                fs.rm(path)
                log.info("Removed existing success.marker at %s", artifact_root)
        except Exception as e:
            log.warning("Could not remove success.marker: %s", e)
    return {"early_exit": False}

def run_pipeline_local() -> Dict[str, Any]:
    force_rerun = os.environ.get("FORCE_RERUN", "false").lower() in ("1", "true", "yes")
    boot = bootstrap_and_hash()
    artifact_root = boot["artifact_root"]
    run_id = boot["run_id"]
    full = boot["full_config_hash"]
    data_fp = boot["data_fingerprint"]
    gate = idempotence_gate(artifact_root, full, data_fp, force_rerun=force_rerun)
    if gate.get("early_exit"):
        return {"run_id": run_id, "artifact_root": artifact_root, "early_exit": True, "reason": gate.get("reason")}
    try:
        import fsspec
        fs, _ = fsspec.core.url_to_fs(artifact_root)
        if hasattr(fs, "makedirs"):
            fs.makedirs(artifact_root.rstrip("/") + "/.tmp", exist_ok=True)
    except Exception:
        log.warning("Could not create artifact .tmp directory; continuing")
    from preprocessing import run_preprocessing
    from config import load_from_env
    cfg = load_from_env()
    feat_uri, fe_meta = run_preprocessing(cfg=cfg, artifact_root=artifact_root, run_id=run_id)
    from train import run_train_and_eval
    schema_uri = fe_meta.get("schema_uri")
    model_uri, train_meta = run_train_and_eval(
        features_uri=feat_uri,
        feature_schema_uri=schema_uri,
        artifact_root=artifact_root,
        run_id=run_id,
        full_config_hash=full,
        data_fingerprint=data_fp,
        cfg=cfg,
    )
    try:
        import fsspec
        marker_uri = artifact_root.rstrip("/") + "/success.marker"
        fs, _ = fsspec.core.url_to_fs(marker_uri)
        tmp = marker_uri + ".tmp"
        with fs.open(tmp, "wb") as fh:
            fh.write(b"")
        if hasattr(fs, "rename"):
            fs.rename(tmp, marker_uri)
        else:
            fs.copy(tmp, marker_uri)
            fs.rm(tmp)
    except Exception as e:
        log.warning("Could not create success.marker: %s", e)
    return {
        "run_id": run_id,
        "artifact_root": artifact_root,
        "model_uri": model_uri,
        "metrics": train_meta.get("metrics"),
        "mlflow": train_meta.get("mlflow"),
    }

if __name__ == "__main__":
    try:
        out = run_pipeline_local()
        print(json.dumps(out, indent=2))
        sys.exit(0)
    except Exception as e:
        log.exception("Pipeline failed: %s", e)
        sys.exit(2)
