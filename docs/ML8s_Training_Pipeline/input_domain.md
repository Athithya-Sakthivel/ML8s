# Full input domain — concise, precise tables

Below are the input variables grouped by purpose. Columns: **Variable**, **Type**, **Affects RUN_ID** (identity), **Required**, **Default**, **Stage(s)**, **One-line purpose**.

---

## 0. Bootstrap / global

| Variable                   |                Type | Affects RUN_ID | Required | Default                     | Stage(s)             | Purpose                                       |
| -------------------------- | ------------------: | :------------: | :------: | --------------------------- | -------------------- | --------------------------------------------- |
| `PIPELINE_ROOT_URI`        |        string (URI) |       No       |    Yes   | `""`                        | bootstrap / pipeline | Artifact root (s3:// or file://).             |
| `DATA_ROOT`                |        string (URI) |     **Yes**    |    Yes   | `""`                        | bootstrap / FE       | Input data root (s3/gs/file).                 |
| `CANONICALIZATION_VERSION` |              string |     **Yes**    |    No    | `1.0.0`                     | bootstrap            | Canonicalization rules version.               |
| `STRICT_DATA_FINGERPRINT`  |                bool |     **Yes**    |    No    | `true`                      | bootstrap            | Include DATA_FINGERPRINT in FULL_CONFIG_HASH. |
| `LOG_LEVEL`                |              string |       No       |    No    | `INFO`                      | all                  | Logging verbosity.                            |
| `REDACTED_ENV_KEYS`        | string (comma list) |       No       |    No    | `AWS_SECRET_ACCESS_KEY,...` | bootstrap            | Keys to redact in snapshots.                  |

---

## 1. Schema governance & validation

| Variable                     |   Type | Affects RUN_ID | Required | Default  | Stage(s)        | Purpose                               |      |                                |
| ---------------------------- | -----: | :------------: | -------: | -------- | --------------- | ------------------------------------- | ---- | ------------------------------ |
| `SCHEMA_ENFORCEMENT_MODE`    |   enum |       No       |       No | `strict` | FE / validation | strict                                | warn | off behavior for schema drift. |
| `EXPECTED_SCHEMA_HASH`       | string |       No       |       No | `""`     | FE              | Optional expected schema fingerprint. |      |                                |
| `ALLOW_NEW_COLUMNS`          |   bool |       No       |       No | `false`  | FE              | Allow additive columns.               |      |                                |
| `ALLOW_COLUMN_TYPE_COERCION` |   bool |       No       |       No | `false`  | FE              | Auto-coerce dtypes when true.         |      |                                |

---

## 2. Task / problem definition (identity-critical)

| Variable           |   Type |   Affects RUN_ID  | Required | Default          | Stage(s)   | Purpose                                          |
| ------------------ | -----: | :---------------: | -------: | ---------------- | ---------- | ------------------------------------------------ |
| `TASK_TYPE`        |   enum |      **Yes**      |      Yes | `classification` | FE / train | Problem family (classification/regression/etc.). |
| `TASK_SUBTYPE`     | string |  **Yes (if set)** |       No | `""`             | train      | Fine-grain subtype.                              |
| `TARGET_COLUMN`    | string |      **Yes**      |    Cond. | `""`             | FE / train | Label column (required for supervised).          |
| `TARGET_DATAFRAME` | string | **Yes (if used)** |       No | `""`             | FE         | Anchor table name (multi-table).                 |
| `SAMPLE_ROWS`      |    int |      **Yes**      |       No | `0`              | FE         | Sample cap for FE (0 = full).                    |

---

## 3. Timeseries / panel (identity when enabled)

| Variable            |   Type |     Affects RUN_ID    | Required | Default | Stage(s)   | Purpose                                     |
| ------------------- | -----: | :-------------------: | -------: | ------- | ---------- | ------------------------------------------- |
| `ENABLE_TIME_SPLIT` |   bool |        **Yes**        |       No | `false` | train      | Use time-ordered split.                     |
| `TIME_COLUMN`       | string |  **Yes (when used)**  |    Cond. | `""`    | FE / train | Time column name for splits/features.       |
| `GROUP_COLUMN`      | string |        **Yes**        |       No | `""`    | FE         | Panel/group ID.                             |
| `FORECAST_HORIZON`  |    int | **Yes (forecasting)** |    Cond. | `1`     | FE/train   | Horizon for forecasting (not full support). |

---

## 4. Data-level safety (pre-read checks)

| Variable                     | Type | Affects RUN_ID | Required | Default   | Stage(s) | Purpose                                 |
| ---------------------------- | ---: | :------------: | -------: | --------- | -------- | --------------------------------------- |
| `MAX_ROWS_FULL_LOAD`         |  int |       No       |       No | `2000000` | FE       | Platform cap on rows to load.           |
| `ESTIMATE_SIZE_SAMPLE_BYTES` |  int |       No       |       No | `1000000` | FE       | Bytes sampled to estimate avg row size. |

---

## 5. FE scale & Ray settings (runtime)

| Variable                  |       Type | Affects RUN_ID | Required | Default | Stage(s) | Purpose                                      |
| ------------------------- | ---------: | :------------: | -------: | ------- | -------- | -------------------------------------------- |
| `ENABLE_RAY_TRANSFORMS`   |       bool |     **Yes**    |       No | `true`  | FE       | Use Ray Data for FE (implementation choice). |
| `RAY_ADDRESS`             |     string |       No       |       No | `local` | FE       | Ray address to connect.                      |
| `RAY_NUM_CPUS`            |        int |       No       |       No | `4`     | FE       | Ray CPU budget.                              |
| `RAY_NUM_GPUS`            |        int |       No       |       No | `0`     | FE       | Ray GPU budget.                              |
| `FE_PARALLELISM`          |        int |       No       |       No | `8`     | FE       | Ray map parallelism override.                |
| `FE_BATCH_SIZE`           |        int |       No       |       No | `50000` | FE       | Rows per map_batches.                        |
| `RAY_USE_STREAMING`       | bool/empty |       No       |       No | `""`    | FE       | Streaming override.                          |
| `RAY_OBJECT_STORE_MEMORY` |     string |       No       |       No | `""`    | FE       | Ray object-store memory hint.                |

---

## 6. Featuretools / automated FE (identity when enabled)

| Variable              |   Type |  Affects RUN_ID  | Required | Default | Stage(s) | Purpose                     |
| --------------------- | -----: | :--------------: | -------: | ------- | -------- | --------------------------- |
| `ENABLE_FEATURETOOLS` |   bool |      **Yes**     |       No | `false` | FE       | Use Featuretools DFS.       |
| `FT_TARGET_ENTITY`    | string | **Yes (if set)** |       No | `""`    | FE       | FT target entity name.      |
| `FT_MAX_DEPTH`        |    int |      **Yes**     |       No | `2`     | FE       | DFS depth.                  |
| `FT_MAX_FEATURES`     |    int |      **Yes**     |       No | `500`   | FE       | Cap for generated features. |
| `FT_USE_TIME_INDEX`   |   bool |      **Yes**     |       No | `true`  | FE       | Reapply time index dtypes.  |

---

## 7. FE pruning & lags (identity)

| Variable                  |      Type |   Affects RUN_ID  | Required | Default | Stage(s) | Purpose                           |
| ------------------------- | --------: | :---------------: | -------: | ------- | -------- | --------------------------------- |
| `MAX_FEATURES`            |       int |      **Yes**      |       No | `1000`  | FE       | Final feature cap.                |
| `CORRELATION_THRESHOLD`   |     float |      **Yes**      |       No | `0.95`  | FE       | Correlation pruning threshold.    |
| `MAX_MISSING_RATIO`       |     float |      **Yes**      |       No | `0.8`   | FE       | Drop columns above this fraction. |
| `ENABLE_LAG_FEATURES`     |      bool |      **Yes**      |       No | `false` | FE       | Create lag features when true.    |
| `LAG_PERIODS`             | list[int] | **Yes (if used)** |       No | `""`    | FE       | Comma list of lags.               |
| `ENABLE_ROLLING_FEATURES` |      bool |      **Yes**      |       No | `false` | FE       | Rolling-window features.          |
| `ROLLING_WINDOWS`         | list[int] | **Yes (if used)** |       No | `7`     | FE       | Comma list of windows.            |

---

## 8. Split strategy & CV (identity/runtime)

| Variable             |   Type |  Affects RUN_ID  | Required | Default | Stage(s) | Purpose                       |        |            |       |      |
| -------------------- | -----: | :--------------: | -------: | ------- | -------- | ----------------------------- | ------ | ---------- | ----- | ---- |
| `SPLIT_STRATEGY`     |   enum |      **Yes**     |       No | `auto`  | train    | split: auto                   | random | stratified | group | time |
| `TRAIN_SIZE`         |  float |      **Yes**     |       No | `0.8`   | train    | Train fraction.               |        |            |       |      |
| `CV_FOLDS`           |    int |      **Yes**     |       No | `5`     | train    | Cross-val folds (0 disables). |        |            |       |      |
| `STRATIFY_BY`        | string | **Yes (if set)** |       No | `""`    | train    | Column for stratified split.  |        |            |       |      |
| `GROUP_SPLIT_COLUMN` | string | **Yes (if set)** |       No | `""`    | train    | Column for group CV.          |        |            |       |      |

---

## 9. FE caching & execution control

| Variable        |   Type | Affects RUN_ID | Required | Default | Stage(s) | Purpose                              |
| --------------- | -----: | :------------: | -------: | ------- | -------- | ------------------------------------ |
| `CACHE_ENABLED` |   bool |       No       |       No | `true`  | FE       | Use table/FE cache.                  |
| `CACHE_VERSION` | string |     **Yes**    |       No | `v1`    | FE       | Cache invalidation version.          |
| `FORCE_RERUN`   |   bool |       No       |       No | `false` | pipeline | Force rerun ignoring success.marker. |

---

## 10. Pipeline mode & warm start

| Variable              |   Type | Affects RUN_ID | Required | Default | Stage(s)       | Purpose               |         |             |
| --------------------- | -----: | :------------: | -------: | ------- | -------------- | --------------------- | ------- | ----------- |
| `PIPELINE_MODE`       |   enum |       No       |       No | `full`  | pipeline       | fe_only               | retrain | full modes. |
| `EXISTING_MODEL_PATH` | string |       No       |       No | `""`    | pipeline/train | Warm-start model URI. |         |             |

---

## 11. Reproducibility & determinism

| Variable                 | Type | Affects RUN_ID | Required | Default | Stage(s)   | Purpose                              |
| ------------------------ | ---: | :------------: | -------: | ------- | ---------- | ------------------------------------ |
| `GLOBAL_RANDOM_SEED`     |  int |     **Yes**    |       No | `42`    | FE / train | Global RNG seed for determinism.     |
| `DETERMINISTIC_TRAINING` | bool |       No       |       No | `true`  | train      | Enforce deterministic backend flags. |

---

## 12. Training / AutoML / HPO (identity)

| Variable                         |         Type | Affects RUN_ID | Required | Default   | Stage(s) | Purpose                            |                              |       |     |
| -------------------------------- | -----------: | :------------: | -------: | --------- | -------- | ---------------------------------- | ---------------------------- | ----- | --- |
| `AUTOML_TIME_BUDGET`             |      int (s) |     **Yes**    |       No | `0`       | train    | Seconds for FLAML; 0 disables.     |                              |       |     |
| `N_CONCURRENT_TRIALS`            |          int |       No       |       No | `1`       | train    | Concurrent HPO trials (ray/hyper). |                              |       |     |
| `MODEL_LIST`                     | list[string] |     **Yes**    |       No | `""`      | train    | Comma-list to restrict models.     |                              |       |     |
| `HANDLE_IMBALANCE`               |         bool |     **Yes**    |       No | `false`   | train    | Apply imbalance mitigation.        |                              |       |     |
| `IMBALANCE_STRATEGY`             |         enum |     **Yes**    |       No | `auto`    | train    | auto                               | class_weight                 | smote | ... |
| `MAX_CLASS_IMBALANCE_RATIO`      |          int |       No       |       No | `10`      | train    | Threshold to force mitigation.     |                              |       |     |
| `MODEL_BACKEND`                  |         enum |       No       |       No | `sklearn` | train    | sklearn                            | lightgbm (pytorch not used). |       |     |
| `DISTRIBUTED_TRAINING`           |         bool |       No       |       No | `false`   | train    | Multi-node training flag.          |                              |       |     |
| `TRAINING_FRAMEWORK`             |         enum |       No       |       No | `native`  | train    | native                             | ray_train.                   |       |     |
| `TRAINING_STAGE_TIMEOUT_SECONDS` |          int |       No       |       No | `3600`    | training | Per-stage timeout.                 |                              |       |     |
| `TRAINING_PIPELINE_MAX_SECONDS`  |          int |       No       |       No | `7200`    | pipeline | Overall runtime cap.               |                              |       |     |

---

## 13. Resource hints (scheduling/runtime-only)

| Variable               |   Type | Affects RUN_ID | Required | Default | Stage(s)   | Purpose                      |
| ---------------------- | -----: | :------------: | -------: | ------- | ---------- | ---------------------------- |
| `FE_CPU_REQUEST`       |    int |       No       |       No | `4`     | scheduling | Request CPUs for FE tasks.   |
| `FE_MEMORY_REQUEST`    | string |       No       |       No | `8Gi`   | scheduling | Memory request for FE.       |
| `TRAIN_CPU_REQUEST`    |    int |       No       |       No | `8`     | scheduling | CPU for training.            |
| `TRAIN_MEMORY_REQUEST` | string |       No       |       No | `32Gi`  | scheduling | Memory request for training. |
| `TRAIN_GPU`            |    int |       No       |       No | `0`     | scheduling | GPUs to request.             |

---

## 14. Evaluation / gating (runtime)

| Variable                 |   Type |  Affects RUN_ID  | Required | Default | Stage(s) | Purpose                      |
| ------------------------ | -----: | :--------------: | -------: | ------- | -------- | ---------------------------- |
| `PRIMARY_METRIC`         | string | **Yes (if set)** |       No | `""`    | train    | Metric used for selection.   |
| `MIN_ACCEPTABLE_METRIC`  |  float |        No        |       No | `""`    | train    | Acceptance threshold.        |
| `EARLY_STOPPING_ENABLED` |   bool |        No        |       No | `true`  | train    | Use early stopping.          |
| `EARLY_STOPPING_ROUNDS`  |    int |        No        |       No | `50`    | train    | Early stopping patience.     |
| `SAVE_OOF_PREDICTIONS`   |   bool |        No        |       No | `false` | train    | Save OOF preds for auditing. |

---

## 15. Model export / validation

| Variable                    | Type | Affects RUN_ID | Required | Default  | Stage(s)       | Purpose                                      |
| --------------------------- | ---: | :------------: | -------: | -------- | -------------- | -------------------------------------------- |
| `MODEL_FORMAT`              | enum |     **Yes**    |       No | `joblib` | train          | joblib or onnx export.                       |
| `VALIDATE_MODEL_ON_EXPORT`  | bool |       No       |       No | `true`   | train          | Run parity check on exported model.          |
| `INFERENCE_BATCH_SIZE`      |  int |       No       |       No | `1000`   | train/validate | Batch size for export validation.            |
| `ENABLE_PROBABILITY_OUTPUT` | bool |       No       |       No | `true`   | train          | Require probability outputs for classifiers. |

---

## 16. Model registry / MLflow (runtime-only)

| Variable                   |   Type | Affects RUN_ID | Required | Default     | Stage(s) | Purpose                         |
| -------------------------- | -----: | :------------: | -------: | ----------- | -------- | ------------------------------- |
| `ENABLE_MLFLOW`            |   bool |       No       |       No | `false`     | train    | Enable MLflow logging/registry. |
| `MLFLOW_TRACKING_URI`      | string |       No       |       No | `""`        | train    | MLflow server URI.              |
| `MLFLOW_EXPERIMENT_PREFIX` | string |       No       |       No | `ml8s_runs` | train    | Experiment prefix.              |
| `MLFLOW_MODEL_NAME`        | string |       No       |       No | `""`        | train    | Registry model name.            |

---

## 17. Explainability & metrics (runtime)

| Variable                     | Type | Affects RUN_ID | Required | Default | Stage(s) | Purpose                                     |
| ---------------------------- | ---: | :------------: | -------: | ------- | -------- | ------------------------------------------- |
| `ENABLE_FEATURE_IMPORTANCE`  | bool |       No       |       No | `true`  | train    | Compute global FI.                          |
| `ENABLE_SHAP_VALUES`         | bool |       No       |       No | `false` | train    | Compute SHAP (expensive).                   |
| `MAX_SHAP_SAMPLES`           |  int |       No       |       No | `5000`  | train    | Cap SHAP sample size.                       |
| `EXPORT_BASELINE_STATISTICS` | bool |       No       |       No | `true`  | train    | Persist training stats for drift detection. |

---

## 18. Drift / monitoring hooks (runtime)

| Variable                  | Type | Affects RUN_ID | Required | Default | Stage(s)      | Purpose                     |
| ------------------------- | ---: | :------------: | -------: | ------- | ------------- | --------------------------- |
| `DRIFT_REFERENCE_WINDOW`  | enum |       No       |       No | `train` | train/monitor | Reference window for drift. |
| `EXPORT_PIPELINE_METRICS` | bool |       No       |       No | `true`  | pipeline      | Emit pipeline metrics.      |

---

## 19. Multi-tenancy & namespacing (runtime)

| Variable     |   Type | Affects RUN_ID | Required | Default   | Stage(s) | Purpose                          |
| ------------ | -----: | :------------: | -------: | --------- | -------- | -------------------------------- |
| `TENANT_ID`  | string |       No       |       No | `default` | pipeline | Tenant identifier for isolation. |
| `PROJECT_ID` | string |       No       |       No | `default` | pipeline | Project grouping.                |

---

## 20. PII / privacy (governance/runtime)

| Variable           |         Type | Affects RUN_ID | Required | Default | Stage(s)   | Purpose                                  |
| ------------------ | -----------: | :------------: | -------: | ------- | ---------- | ---------------------------------------- |
| `PII_COLUMNS`      | list[string] |       No       |       No | `""`    | FE/persist | Columns considered PII.                  |
| `HASH_PII_COLUMNS` |         bool |       No       |       No | `true`  | FE/persist | Hash PII instead of dropping.            |
| `LOG_SAMPLE_ROWS`  |         bool |       No       |       No | `false` | logging    | Include sample rows in logs (dangerous). |

---

## 21. Artifact retention & operator

| Variable                  | Type | Affects RUN_ID | Required | Default | Stage(s) | Purpose                                    |
| ------------------------- | ---: | :------------: | -------: | ------- | -------- | ------------------------------------------ |
| `ARTIFACT_RETENTION_DAYS` |  int |       No       |       No | `30`    | ops      | Days to keep artifacts (operator-managed). |

---

## 22. Security / redaction

| Variable            |         Type | Affects RUN_ID | Required | Default                                 | Stage(s)  | Purpose                                |
| ------------------- | -----------: | :------------: | -------: | --------------------------------------- | --------- | -------------------------------------- |
| `REDACTED_ENV_KEYS` | string (csv) |       No       |       No | `AWS_SECRET...,AZURE_CLIENT_SECRET,...` | bootstrap | Keys to redact in persisted snapshots. |

---

## 23. Advanced / operator tuning (runtime)

| Variable                  |   Type | Affects RUN_ID | Required | Default | Stage(s) | Purpose                                      |
| ------------------------- | -----: | :------------: | -------: | ------- | -------- | -------------------------------------------- |
| `RAY_OBJECT_STORE_MEMORY` | string |       No       |       No | `""`    | FE       | Advanced override like "40Gi".               |
| `RAY_USE_STREAMING`       | string |       No       |       No | `""`    | FE       | Advanced override (duplicate in FE section). |

---

## 24. Orchestrator / Flyte (injected/runtime-only)

| Variable             |   Type | Affects RUN_ID | Required | Default | Stage(s)     | Purpose                        |
| -------------------- | -----: | :------------: | -------: | ------- | ------------ | ------------------------------ |
| `FLYTE_PROJECT`      | string |       No       |       No | `""`    | orchestrator | Flyte project meta (injected). |
| `FLYTE_DOMAIN`       | string |       No       |       No | `""`    | orchestrator | Flyte domain.                  |
| `FLYTE_EXECUTION_ID` | string |       No       |       No | `""`    | orchestrator | Flyte execution id (injected). |

---

## 25. Logging / debugging

| Variable    |   Type | Affects RUN_ID | Required | Default | Stage(s) | Purpose                         |
| ----------- | -----: | :------------: | -------: | ------- | -------- | ------------------------------- |
| `LOG_LEVEL` | string |       No       |       No | `INFO`  | all      | Logging level; used everywhere. |

---
