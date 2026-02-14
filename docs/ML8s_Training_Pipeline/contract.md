# Deterministic & Idempotent Training Pipeline — Runtime Control Flow (Converged Contract)

This document defines the exact, enforceable runtime control flow for the platform’s training pipeline. It states precise responsibilities, concrete algorithms, exact artifact layouts, and the deterministic/idempotent checkpoints. Use this as the single source of truth for engineering and operations.

---

## Purpose

Provide a deterministic, idempotent training run such that **identical inputs produce identical artifacts at the exact same deterministic path** and **re-runs do not produce duplicate artifacts or model registry entries**.

---

## Scope

Applies to every pipeline execution launched by Flyte (or other orchestrators) that produces FE artifacts, trained models, exports, metrics, and registry records. This contract is authoritative — platform code and tasks must implement exactly as specified.

---

## Key Definitions (precise)

* **Canonical user config** — JSON object constructed only from user-level env vars listed under “USER-LEVEL (affects model identity)”. Values normalized per rules below.
* **DATA_FINGERPRINT** — SHA-256 hex string representing the dataset state (object store etags OR file checksums) computed by exact algorithm below.
* **FULL_CONFIG_HASH** — `sha256(canonical_config_json + "\n" + DATA_FINGERPRINT)` using exact serialization and concatenation rules below.
* **RUN_ID** — first 12 lowercase hex characters of FULL_CONFIG_HASH. FULL_CONFIG_HASH is persisted; RUN_ID is used in paths and UI.
* **ARTIFACT_ROOT** — `{PIPELINE_ROOT_URI}/ml8s_training_runs/{RUN_ID}`.
* **Atomic write** — write to `{ARTIFACT_ROOT}/.tmp/{component}-{workerid}.{ext}` and then atomic rename/move to final location.

---

## Hard Invariants (must be enforced)

1. **Only** canonical user-level variables (and DATA_FINGERPRINT when in strict mode) are input to FULL_CONFIG_HASH. No platform, secret, scheduling, or runtime-only var enters the hash.
2. Canonicalization algorithm is stable and immutable across versions unless a deliberate breaking change is released (see versioning note).
3. ARTIFACT_ROOT is a pure function of PIPELINE_ROOT_URI and RUN_ID only. No timestamps, execution IDs, or random UUIDs appear in final paths.
4. Every artifact write uses the Atomic write protocol.
5. MLflow entries include `run_id` = RUN_ID and `full_config_hash` = FULL_CONFIG_HASH.
6. Platform stores FULL_CONFIG_HASH in `config_snapshot.json` under ARTIFACT_ROOT.
7. Duplicate RUN_ID detection uses the presence of a finalized `success.marker` file at ARTIFACT_ROOT.

---

## Canonicalization Rules (exact)

1. Collect only user-level env vars that affect model identity (the list from the finalized export block).
2. Normalize values:

   * Trim whitespace.
   * Normalize booleans to literal `true` / `false` (lowercase).
   * Convert numeric strings to numbers.
   * Convert comma-separated lists to arrays; remove empty items; sort lexicographically; deduplicate.
   * Empty strings become JSON `null`.
3. Sort JSON keys lexicographically.
4. Serialize with no whitespace, UTF-8, and deterministic ordering: `json.dumps(obj, separators=(',', ':'), sort_keys=True, ensure_ascii=False)`.
5. Produce `CANONICAL_JSON` as the single-line output of step 4.

---

## DATA_FINGERPRINT Algorithm (exact)

### For object stores (s3://, gcs://, azure://)

1. List all files under DATA_ROOT using the provider’s API; produce a list of tuples `(relative_path, etag_or_md5, size)`.
2. Sort tuples by `relative_path` lexicographically.
3. For each tuple produce a token `"{relative_path}:{etag_or_md5}:{size}"`.
4. Concatenate tokens using pipe `|` as separator into a single bytestring.
5. Compute `DATA_FINGERPRINT = sha256(bytestring).hexdigest()` (lowercase hex).

### For local file systems (file:///)

1. Traverse DATA_ROOT; produce `(relative_path, inode_modtime, size)` or `(relative_path, sha256(file_bytes))`.
2. Preferred: use `sha256(file_bytes)` for each file for absolute determinism.
3. Sort and concatenate tokens as above and compute sha256.

### Implementation requirements

* Use provider APIs that return stable etags. For multipart objects use provider-specific deterministic checksums (include ETag and size).
* Do not use last-modified alone unless strongly versioned; prefer etag or content checksum.

---

## FULL_CONFIG_HASH & RUN_ID Computation (exact)

1. Construct `CANONICAL_JSON` per canonicalization rules.
2. Append newline, then `DATA_FINGERPRINT` as `CANONICAL_JSON + "\n" + DATA_FINGERPRINT`.
3. Compute `FULL_CONFIG_HASH = sha256(byte_sequence).hexdigest()` (lowercase 64 hex chars).
4. Compute `RUN_ID = FULL_CONFIG_HASH[0:12]` (lowercase).
5. Persist `config_snapshot.json` at `{ARTIFACT_ROOT}/config_snapshot.json` containing:

   ```json
   {
     "canonical_config": <object>,
     "data_fingerprint": "<DATA_FINGERPRINT>",
     "full_config_hash": "<FULL_CONFIG_HASH>",
     "run_id": "<RUN_ID>",
     "canonicalization_version": "<SEMVER>"
   }
   ```

---

## ARTIFACT PATH LAYOUT (exact)

All artifacts reside only under:

```
{PIPELINE_ROOT_URI}/ml8s_training_runs/{RUN_ID}/
    config_snapshot.json
    data_fingerprint.json
    success.marker
    features/
        feature_matrix.parquet
        feature_schema.json
    model/
        model_native.<ext>
        model.<export_ext>  # e.g., .onnx or .joblib
    metrics.json
    training_metadata.json
    logs/   # detailed task logs (optional)
```

`success.marker` is a zero-byte file created atomically at the final step of successful pipeline completion.

---

## Atomic Write Protocol (exact)

1. Each intermediate or final component writes to `{ARTIFACT_ROOT}/.tmp/` with a unique worker id:

   * Example: `{ARTIFACT_ROOT}/.tmp/features-0abcd.parquet`.
2. Validate integrity (size and checksum).
3. Perform atomic rename/move to final path `{ARTIFACT_ROOT}/features/feature_matrix.parquet`.
4. Only after **all** final components successfully moved does the pipeline create `{ARTIFACT_ROOT}/success.marker` (atomic creation).
5. Any failed or partial `.tmp` entries remain isolated and are removed by cleanup jobs after T days.

---

## Runtime Control Flow (step-by-step, deterministic)

All steps use exact inputs and outputs described. Each step must log `RUN_ID` and `FULL_CONFIG_HASH`.

### Step 0 — Bootstrap / Validation

* Read envs.
* Build `CANONICAL_JSON`.
* Compute `DATA_FINGERPRINT` using the object store or file algorithm.
* Compute `FULL_CONFIG_HASH` and `RUN_ID`.
* Derive `ARTIFACT_ROOT = {PIPELINE_ROOT_URI}/ml8s_training_runs/{RUN_ID}`.
* Create local runtime dir for staging.

### Step 1 — Exist & Integrity Check (idempotence gate)

* Check presence of `{ARTIFACT_ROOT}/success.marker`.
* If present:

  * Read `config_snapshot.json`.
  * Verify stored `full_config_hash` equals computed `FULL_CONFIG_HASH`.
  * Verify `data_fingerprint.json` checksum equals computed `DATA_FINGERPRINT`.
  * On exact match: terminate early; return artifact URIs and MLflow model reference.
  * On mismatch: terminate with error indicating hash collision or data drift (no automatic overwrite).
* If not present: proceed to Step 2.

*(Platform must set `FORCE_RERUN=true` to bypass the early-termination behavior but FORCE_RERUN does not change RT invariants; its behavior is declared in Step 1 override section.)*

### Step 2 — Data Load & Snapshot

* Read dataset deterministically:

  * Use stable ordering of file listing and stable chunk order when concatenating.
  * Apply `SAMPLE_ROWS` deterministically.
* Persist `data_fingerprint.json` to `.tmp` and then atomically move to `{ARTIFACT_ROOT}/data_fingerprint.json`.

### Step 3 — Feature Engineering (deterministic)

* Execute FE task container (`Dockerfile.fe`) with `CANONICAL_JSON`, `DATA_FINGERPRINT`, and `RANDOM_SEED`.
* FE task must:

  * Sort columns alphabetically before any pruning.
  * Normalize all categorical encodings with deterministic order.
  * Use sorted lists for any generated feature names.
  * Enforce `MAX_FEATURES` deterministically by stable selection rule (e.g., top-N by variance with tie-breaking by feature name).
* Write features to `{ARTIFACT_ROOT}/.tmp/features/*.parquet`, validate checksums, then atomic move to `{ARTIFACT_ROOT}/features/`.

### Step 4 — Training (deterministic)

* Run training container (`Dockerfile.train`) with explicit `RANDOM_SEED` and `CANONICAL_JSON`.
* Training code must pass `RANDOM_SEED` to all libraries and AutoML engines and set deterministic GPU flags as required by frameworks.
* Persist `training_metadata.json` and `metrics.json` to `.tmp` then atomic move into `{ARTIFACT_ROOT}/model/` and `{ARTIFACT_ROOT}/`.

### Step 5 — Model Export & Validation

* Export native model to `model_native.<ext>`.
* Export final artifact per `MODEL_FORMAT` to `model.<export_ext>`.
* Compute sha256 checksums for model files and store them in `training_metadata.json`.
* Move atomically to the final model directory.

### Step 6 — MLflow Registration (idempotent)

* Create or fetch MLflow experiment determined by `MLFLOW_EXPERIMENT_PREFIX`.
* Create an MLflow run with tags:

  * `run_id` = RUN_ID
  * `full_config_hash` = FULL_CONFIG_HASH
  * `data_fingerprint` = DATA_FINGERPRINT
  * `artifact_uri` = `{ARTIFACT_ROOT}/model`
* Register model under the registry backend with version tied to RUN_ID and `full_config_hash`.
* If registration entry for `full_config_hash` exists: record reference; do not re-register duplicate model.

### Step 7 — Finalization

* Verify all expected files exist and checksums match.
* Create atomically `{ARTIFACT_ROOT}/success.marker`.
* Persist `config_snapshot.json` to ARTIFACT_ROOT (atomic write).
* Return a canonical run manifest to caller containing `RUN_ID`, `FULL_CONFIG_HASH`, artifact URIs, and MLflow model reference.

---

## FORCE_RERUN Behavior (explicit)

* Platform exposes `FORCE_RERUN=true` as a runtime override.
* When `FORCE_RERUN=true` platform deletes `{ARTIFACT_ROOT}/success.marker` and any safe final artifacts, then executes Steps 2–7 exactly as above.
* `FORCE_RERUN=true` does not alter canonicalization or hash computation.

---

## Collision / Conflict Handling

* If a computed RUN_ID already exists under ARTIFACT_ROOT but `config_snapshot.json.full_config_hash` differs from computed FULL_CONFIG_HASH, platform halts execution and raises `RUN_ID_HASH_COLLISION` with both FULL_CONFIG_HASH values and worker diagnostic logs.
* Platform stores both FULL_CONFIG_HASH and parent RUN_ID in the incident log for audit.

---

## Flyte & Task-Level Contracts (explicit)

* Flyte handles orchestration only; Flyte execution IDs must not influence any hash or artifact path.
* Annotate tasks with `cache=True` and `cache_version=<IMAGE_VERSION>` strictly for performance. Caching is advisory and never used to determine RUN_ID.
* Tasks must accept and log `canoncial_config` and `full_config_hash` in their input metadata.

---

## MLflow Contract (explicit)

* MLflow run tag keys: `run_id`, `full_config_hash`, `data_fingerprint`, `artifact_uri`.
* MLflow model registry entries must reference `{ARTIFACT_ROOT}/model` and contain `full_config_hash` metadata.
* Platform enforces no duplicate registry creation for the same `full_config_hash`.

---

## Verification & Auditing (post-run verification steps)

Platform must provide a verification endpoint that performs:

1. Read `{ARTIFACT_ROOT}/config_snapshot.json`.
2. Recompute `sha256` of each artifact listed and verify against `training_metadata.json`.
3. Confirm that MLflow tags contain matching `run_id` and `full_config_hash`.
4. Report PASS/FAIL and produce an audit bundle with provenance for legal or compliance needs.

---

## Example Concrete Commands (exact; POSIX)

Canonical JSON and hashes (example):

```sh
# canonicalization shell example (requires jq)
# 1) Build canonical JSON from selected env variables (platform does this; example shown)
CANONICAL_JSON=$(jq -n \
  --arg data_root "$DATA_ROOT" \
  --arg target_column "$TARGET_COLUMN" \
  --arg model_format "$MODEL_FORMAT" \
  --argjson test_size "$TEST_SIZE" \
  --argjson random_seed "$RANDOM_SEED" \
  '{data_root:$data_root, target_column:$target_column, model_format:$model_format, test_size:$test_size, random_seed:$random_seed}' \
  | jq -cS .)  # -cS = compact + sorted keys

# 2) Compute data fingerprint (s3 example uses aws cli and jq)
aws s3api list-objects-v2 --bucket ml-bucket --prefix churn/raw --query 'Contents[].{Key:Key,ETag:ETag,Size:Size}' \
  | jq -r '.[] | "\(.Key):\(.ETag|gsub("\"";"")):\(.Size)"' \
  | sort \
  | paste -sd'|' - \
  | tee /tmp/dataset_tokens.txt \
  | xargs -0 printf "%s" \
  | sha256sum | awk '{print $1}' > /tmp/data_fingerprint.txt

DATA_FINGERPRINT=$(cat /tmp/data_fingerprint.txt)

# 3) Compute full hash and run id
FULL_CONFIG_HASH=$(printf '%s\n%s' "$CANONICAL_JSON" "$DATA_FINGERPRINT" | sha256sum | awk '{print $1}')
RUN_ID=${FULL_CONFIG_HASH:0:12}
```

Atomic move (POSIX, S3 needs provider-atomic move emulation):

```sh
# local atomic move
mv /tmp/staging/feature_matrix.parquet /mnt/artifacts/ml8s_training_runs/${RUN_ID}/features/feature_matrix.parquet
# on S3: upload to .tmp then use s3 mv (s3 mv is rename)
aws s3 cp /tmp/staging/feature_matrix.parquet s3://ml-bucket/projectA/ml8s_training_runs/${RUN_ID}/.tmp/feature_matrix.parquet
aws s3 mv s3://ml-bucket/projectA/ml8s_training_runs/${RUN_ID}/.tmp/feature_matrix.parquet s3://ml-bucket/projectA/ml8s_training_runs/${RUN_ID}/features/feature_matrix.parquet
```

---

## Operational Notes (mandatory)

* Bump `canonicalization_version` in `config_snapshot.json` when canonicalization changes. Old runs remain immutable.
* Maintain a background cleanup job to remove stale `.tmp/` remnants after retention period.
* Enforce `ARTIFACT_RETENTION_DAYS` policy via lifecycle rules on the bucket/container.
* Provide an operator tool to resolve `RUN_ID_HASH_COLLISION` only after audit.

---

## Conclusion (single-line contract)

A run is deterministic and idempotent when `RUN_ID = prefix(sha256(canonical_user_config_json + "\n" + DATA_FINGERPRINT))`, all artifact writes use the Atomic write protocol under `{PIPELINE_ROOT_URI}/ml8s_training_runs/{RUN_ID}`, and MLflow entries are registered using `full_config_hash` as the canonical model identity. Implement everything in this document exactly.

---
