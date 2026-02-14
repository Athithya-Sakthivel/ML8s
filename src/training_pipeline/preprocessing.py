#!/usr/bin/env python3
from typing import Dict, Any, List, Optional, Tuple
import logging
import time
import random

import pandas as pd
import numpy as np

from config import PlatformConfig
from contracts import FeatureOutput, FeatureSchema, FeatureColumn, TableManifest, TableFileToken

import io as io_utils

log = logging.getLogger("ml8s.preprocessing")
log.setLevel(__import__("os").environ.get("LOG_LEVEL", "INFO"))

_SAMPLE_ROWS_DEFAULT = 200
_FEATURETOOLS_N_JOBS = 1

def _maybe_init_ray(cfg: PlatformConfig):
    if not cfg.ENABLE_RAY_TRANSFORMS:
        log.info("Ray transforms disabled by config")
        return None
    try:
        import ray
        try:
            addr = (cfg.RAY_ADDRESS or "").strip()
            if addr and addr.lower() != "local" and addr.lower() != "none":
                ray.init(address=addr, ignore_reinit_error=True)
                log.info("Connected to Ray at address=%s", addr)
            else:
                try:
                    ray.init(ignore_reinit_error=True)
                    log.info("Ray local init succeeded")
                except Exception:
                    log.info("Ray local init not available; falling back to pandas")
                    return None
        except Exception as e:
            log.warning("Failed to init/connect Ray: %s; falling back to pandas", e)
            return None
        return ray
    except Exception:
        log.info("Ray not installed/available; using pandas path")
        return None

def _discover_tables(data_root: str) -> Dict[str, List[str]]:
    files = io_utils.list_files(data_root, recursive=True)
    if not files:
        raise RuntimeError("No files discovered under DATA_ROOT=%s" % data_root)
    root_prefix = data_root.rstrip("/")
    tables: Dict[str, List[str]] = {}
    for f in files:
        rel = f
        if str(f).startswith(str(root_prefix)):
            rel = str(f)[len(str(root_prefix)):].lstrip("/")
        parts = rel.split("/")
        if len(parts) > 1:
            table = parts[0]
        else:
            basename = str(f).split("/")[-1]
            import re
            m = re.match(r"^([A-Za-z0-9_]+)", basename)
            table = m.group(1) if m else basename.rsplit(".", 1)[0]
        tables.setdefault(table, []).append(f)
    for k in list(tables.keys()):
        tables[k] = sorted(tables[k])
    return tables

def _read_sample_for_table(files: List[str], cfg: PlatformConfig, ray_mod=None, nrows: int = 0) -> pd.DataFrame:
    if nrows is None or nrows <= 0:
        nrows = _SAMPLE_ROWS_DEFAULT
    if ray_mod:
        try:
            ds = ray_mod.data.read_parquet(files)
            try:
                sample = ds.take(nrows)
                if isinstance(sample, list) and sample:
                    return pd.DataFrame(sample)
                return ds.limit(nrows).to_pandas()
            except Exception:
                return ds.limit(nrows).to_pandas()
        except Exception as e:
            log.info("Ray read_parquet failed for sample; falling back to pandas: %s", e)
    parts = []
    read = 0
    for f in files:
        try:
            df = pd.read_parquet(f)
            if df is None or df.empty:
                continue
            if read + len(df) <= nrows:
                parts.append(df)
                read += len(df)
            else:
                need = nrows - read
                if need > 0:
                    parts.append(df.head(need))
                    read += need
                break
        except Exception as e:
            log.warning("Failed to read parquet %s for sampling: %s", f, e)
    if not parts:
        return pd.DataFrame()
    return pd.concat(parts, ignore_index=True).head(nrows)

def _detect_candidate_keys_and_time(df: pd.DataFrame) -> Tuple[List[str], Optional[str]]:
    pks = []
    time_col = None
    for c in df.columns:
        nonnull = df[c].dropna()
        if len(nonnull) == 0:
            continue
        try:
            unique_ratio = nonnull.nunique() / len(nonnull)
            if unique_ratio > 0.98 and len(nonnull) > 10:
                pks.append(c)
        except Exception:
            pass
        if time_col is None:
            try:
                parsed = pd.to_datetime(nonnull, errors="coerce")
                if parsed.notna().sum() / max(1, len(parsed)) > 0.9:
                    time_col = c
            except Exception:
                pass
    return pks, time_col

def _build_relationships(samples: Dict[str, pd.DataFrame], pk_hints: Dict[str, List[str]]) -> List[Tuple[str,str,str,str]]:
    relationships = []
    for parent, parent_df in samples.items():
        pks = pk_hints.get(parent, [])
        for pk in pks:
            parent_set = set(parent_df[pk].dropna().unique().tolist())
            if not parent_set:
                continue
            for child, child_df in samples.items():
                if child == parent or child_df is None or child_df.empty:
                    continue
                for ccol in child_df.columns:
                    child_set = set(child_df[ccol].dropna().unique().tolist())
                    if not child_set:
                        continue
                    overlap = len(parent_set & child_set) / max(1, len(child_set))
                    if overlap >= 0.9 and len(parent_set & child_set) > 5:
                        relationships.append((parent, pk, child, ccol))
    relationships = sorted(list({tuple(r) for r in relationships}))
    return relationships

def _conservative_aggregate_joins(anchor: pd.DataFrame, samples: Dict[str, pd.DataFrame], relationships: List[Tuple[str,str,str,str]]):
    for (parent, parent_col, child, child_col) in relationships:
        try:
            if child not in samples:
                continue
            parent_df = samples[parent]
            if parent_col not in parent_df.columns or child_col not in anchor.columns:
                continue
            numeric_cols = parent_df.select_dtypes(include=["number"]).columns.tolist()
            if not numeric_cols:
                continue
            aggs = parent_df.groupby(parent_col)[numeric_cols].agg(["count","sum","mean"]).fillna(0)
            aggs.columns = ["_".join([c, a]) for c, a in aggs.columns]
            anchor = anchor.join(aggs, on=child_col)
        except Exception as e:
            log.warning("Failed to join relationship (%s,%s,%s,%s): %s", parent, parent_col, child, child_col, e)
    return anchor

def _generate_lag_rolling(anchor: pd.DataFrame, time_col: Optional[str], cfg: PlatformConfig) -> pd.DataFrame:
    out = anchor.copy()
    if cfg.ENABLE_LAG_FEATURES and time_col and time_col in out.columns:
        out = out.sort_values(by=time_col).reset_index(drop=True)
        periods = cfg.LAG_PERIODS or []
        for p in periods:
            for c in out.select_dtypes(include=["number"]).columns:
                out[f"{c}_lag_{p}"] = out[c].shift(p)
    if cfg.ENABLE_ROLLING_FEATURES and time_col and time_col in out.columns:
        out = out.sort_values(by=time_col).reset_index(drop=True)
        windows = cfg.ROLLING_WINDOWS or []
        for w in windows:
            for c in out.select_dtypes(include=["number"]).columns:
                out[f"{c}_roll_mean_{w}"] = out[c].rolling(window=w, min_periods=1).mean()
    return out

def _prune_columns(anchor: pd.DataFrame, cfg: PlatformConfig) -> Tuple[pd.DataFrame, List[str], List[str]]:
    max_missing = float(cfg.MAX_MISSING_RATIO)
    null_frac = anchor.isnull().mean()
    drop_null = null_frac[null_frac > max_missing].index.tolist()
    if drop_null:
        anchor = anchor.drop(columns=drop_null, errors="ignore")
    nunique = anchor.nunique(dropna=True)
    drop_const = nunique[nunique <= 1].index.tolist()
    if drop_const:
        anchor = anchor.drop(columns=drop_const, errors="ignore")
    numeric = anchor.select_dtypes(include=["number"])
    dropped_by_corr = []
    if numeric.shape[1] >= 2 and cfg.CORRELATION_THRESHOLD > 0:
        corr = numeric.corr().abs()
        to_drop = set()
        cols_sorted = sorted(corr.columns)
        for i, a in enumerate(cols_sorted):
            if a in to_drop:
                continue
            for b in cols_sorted[i+1:]:
                if b in to_drop:
                    continue
                try:
                    if corr.loc[a, b] >= float(cfg.CORRELATION_THRESHOLD):
                        mean_a = corr[a].mean()
                        mean_b = corr[b].mean()
                        if mean_a > mean_b:
                            drop = a
                        elif mean_b > mean_a:
                            drop = b
                        else:
                            drop = b if a < b else a
                        to_drop.add(drop)
                except Exception:
                    continue
        dropped_by_corr = sorted(list(to_drop))
        if dropped_by_corr:
            anchor = anchor.drop(columns=dropped_by_corr, errors="ignore")
    dropped_by_max = []
    if anchor.shape[1] > int(cfg.MAX_FEATURES):
        variances = anchor.var(numeric_only=True).to_dict()
        cols = list(anchor.columns)
        ranked = sorted(cols, key=lambda c: (-variances.get(c, 0.0), c))
        keep = ranked[:int(cfg.MAX_FEATURES)]
        drop = [c for c in cols if c not in keep]
        anchor = anchor[keep]
        dropped_by_max = sorted(drop)
    return anchor, dropped_by_corr, dropped_by_max

def _build_feature_schema(anchor: pd.DataFrame, dropped_by_corr: List[str], dropped_by_max: List[str]) -> FeatureSchema:
    columns = []
    for c in anchor.columns:
        dtype = str(anchor[c].dtype)
        nullable = bool(anchor[c].isnull().any())
        columns.append(FeatureColumn(name=c, dtype=dtype, nullable=nullable))
    schema = FeatureSchema(columns=columns, num_rows=int(len(anchor)), num_columns=len(columns), dropped_by_corr=dropped_by_corr, dropped_by_max=dropped_by_max)
    return schema

def run_preprocessing(cfg: PlatformConfig, artifact_root: str, run_id: str) -> Tuple[str, Dict[str, Any]]:
    start = time.time()
    random.seed(int(cfg.GLOBAL_RANDOM_SEED or 42))
    np.random.seed(int(cfg.GLOBAL_RANDOM_SEED or 42))
    ray_mod = _maybe_init_ray(cfg)
    data_root = cfg.DATA_ROOT
    tables = _discover_tables(data_root)
    samples: Dict[str, pd.DataFrame] = {}
    pk_hints: Dict[str, List[str]] = {}
    time_hints: Dict[str, Optional[str]] = {}
    sample_rows = int(cfg.SAMPLE_ROWS) if cfg.SAMPLE_ROWS and int(cfg.SAMPLE_ROWS) > 0 else _SAMPLE_ROWS_DEFAULT
    for t, files in sorted(tables.items()):
        df_sample = _read_sample_for_table(files, cfg, ray_mod=ray_mod, nrows=sample_rows)
        samples[t] = df_sample
        pks, tcol = _detect_candidate_keys_and_time(df_sample)
        pk_hints[t] = pks
        time_hints[t] = tcol
        log.info("table=%s sample_rows=%d cols=%d pk_hints=%s time_hint=%s", t, len(df_sample), len(df_sample.columns) if not df_sample.empty else 0, pks, tcol)
    anchor_name = cfg.TARGET_DATAFRAME if cfg.TARGET_DATAFRAME and cfg.TARGET_DATAFRAME in samples else None
    if anchor_name:
        anchor = samples[anchor_name].copy()
    else:
        best = max(samples.items(), key=lambda kv: (getattr(kv[1], "shape", (0,0))[0], kv[0]))[0]
        anchor = samples[best].copy()
        anchor_name = best
    if "id" in anchor.columns:
        anchor = anchor.set_index("id", drop=False)
    else:
        anchor = anchor.reset_index(drop=True).reset_index().rename(columns={"index": "generated_index"}).set_index("generated_index", drop=False)
    relationships = _build_relationships(samples, pk_hints)
    if cfg.ENABLE_FEATURETOOLS:
        try:
            import featuretools as ft
            dataframes = {}
            for name, df in samples.items():
                df_copy = df.copy()
                idx = pk_hints.get(name)[0] if pk_hints.get(name) else None
                tindex = time_hints.get(name)
                if idx:
                    dataframes[name] = (df_copy, idx, tindex)
                else:
                    dataframes[name] = (df_copy, None, tindex)
            rels = [(p, pk, c, cc) for (p, pk, c, cc) in relationships]
            try:
                dfs_result = ft.dfs(dataframes=dataframes, relationships=rels, target_dataframe_name=anchor_name, max_depth=int(cfg.FT_MAX_DEPTH or 2), max_features=int(cfg.FT_MAX_FEATURES or -1), n_jobs=_FEATURETOOLS_N_JOBS)
                if isinstance(dfs_result, tuple) and len(dfs_result) >= 1:
                    anchor = dfs_result[0].copy()
                else:
                    anchor = dfs_result.copy()
                log.info("Featuretools DFS produced feature matrix rows=%d cols=%d", len(anchor), len(anchor.columns))
            except Exception as e:
                log.warning("Featuretools DFS attempt failed: %s; falling back to conservative FE", e)
                anchor = _conservative_aggregate_joins(anchor, samples, relationships)
        except Exception as e:
            log.warning("Featuretools import/detect failed: %s; falling back to conservative FE", e)
            anchor = _conservative_aggregate_joins(anchor, samples, relationships)
    else:
        anchor = _conservative_aggregate_joins(anchor, samples, relationships)
    time_col_candidates = [time_hints.get(anchor_name)] + [v for v in time_hints.values() if v]
    time_col = next((v for v in time_col_candidates if v), None)
    anchor = _generate_lag_rolling(anchor, time_col, cfg)
    anchor = anchor.reindex(sorted(anchor.columns), axis=1)
    anchor, dropped_by_corr, dropped_by_max = _prune_columns(anchor, cfg)
    artifact_features_dir = f"{artifact_root.rstrip('/')}/features"
    features_uri = artifact_features_dir + "/feature_matrix.parquet"
    io_out_uri = io_utils.write_parquet(anchor.reset_index(drop=True), features_uri)
    schema = _build_feature_schema(anchor, dropped_by_corr, dropped_by_max)
    metadata_uri = artifact_features_dir + "/feature_schema.json"
    io_utils.atomic_write_json(schema.dict(), metadata_uri)
    table_manifests = {}
    for t, files in sorted(tables.items()):
        file_tokens = {}
        for p in files:
            try:
                fs, path = io_utils.url_to_fs(p)
                info = fs.info(path)
                token_val = str(info.get("ETag") or info.get("etag") or info.get("md5") or f"size:{info.get('size','')}")
                size_val = int(info.get("size") or 0) if info.get("size") is not None else None
                token = TableFileToken(path=p, token=token_val, size=size_val)
            except Exception:
                token = TableFileToken(path=p, token=f"size:unknown", size=None)
            file_tokens[p] = token
        concat = "|".join([f"{k}:{file_tokens[k].token}:{file_tokens[k].size or ''}" for k in sorted(file_tokens.keys())]).encode("utf-8")
        import hashlib
        tfp = hashlib.sha256(concat).hexdigest()
        table_manifests[t] = TableManifest(files=file_tokens, table_fingerprint=tfp)
    data_fingerprint = None
    try:
        if io_utils.exists(features_uri):
            data_fingerprint = io_utils.compute_sha256_of_uri(features_uri)
    except Exception as e:
        log.warning("Failed to compute feature matrix checksum: %s", e)
    feature_output = FeatureOutput(run_id=run_id, features_uri=features_uri, schema=schema, num_rows=int(len(anchor)), num_columns=int(len(anchor.columns)), data_fingerprint=data_fingerprint, table_manifests=table_manifests, metadata={"dropped_by_corr": dropped_by_corr, "dropped_by_max": dropped_by_max, "time_col": time_col})
    manifest_uri = artifact_features_dir + "/feature_output.json"
    feature_output.save_json(manifest_uri)
    elapsed = time.time() - start
    log.info("Feature engineering complete run_id=%s rows=%d cols=%d elapsed=%.2fs", run_id, int(feature_output.num_rows), int(feature_output.num_columns), elapsed)
    return features_uri, {"features_uri": features_uri, "schema_uri": metadata_uri, "manifest_uri": manifest_uri, "num_rows": int(feature_output.num_rows), "num_columns": int(feature_output.num_columns), "run_id": run_id}
