# ML8s

**Deterministic, Kubernetes-native platform for training, evaluating, deploying, and monitoring classical machine learning models — without requiring Kubernetes expertise.**

---

## Why ML8s

Classical ML systems (fraud detection, churn prediction, demand forecasting, risk scoring, ranking) are widely used in production, yet their lifecycle remains fragmented:

* Models are trained in notebooks.
* Deployment requires containerization and Kubernetes knowledge.
* Evaluation is inconsistent.
* Drift detection is ad hoc.
* Reproducibility is weak.
* Promotion processes lack governance.

ML engineers should not need to understand Kubernetes, Helm, service meshes, or infrastructure primitives to ship production models.

**ML8s solves this by providing a deterministic, config-driven ML lifecycle on Kubernetes.**

---

## Vision

Turn classical ML from an artisanal workflow into an infrastructure capability.

ML8s abstracts infrastructure complexity while enforcing:

* Deterministic training
* Immutable dataset contracts
* Mandatory evaluation
* Controlled model promotion
* Continuous monitoring
* Reproducibility by design

---

## Design Principles

### 1. Deterministic Contracts

Training consumes:

* Immutable dataset snapshot (object store URI)
* Explicit configuration
* Fixed random seed

Training produces:

* Versioned model artifact
* Evaluation report
* Feature manifest
* Dataset reference
* Config snapshot

Reproducible. Auditable. Governable.

---

### 2. Infrastructure Abstraction

ML engineers interact with:

```
ml8s train --config s3://configs/fraud_v3.yaml
ml8s deploy --model-id fraud_v3_20260211
```

ML8s handles:

* Kubernetes Jobs
* Container orchestration
* Model packaging
* Deployments
* Scaling (HPA)
* Rollouts (Canary/Blue-Green)
* Monitoring
* Rollbacks

No Kubernetes expertise required.

---

### 3. Clear Separation of Responsibilities

| Responsibility              | Owner            |
| --------------------------- | ---------------- |
| Raw data cleaning           | Data Engineering |
| Dataset snapshot publishing | Data Engineering |
| Model training & evaluation | ML8s             |
| Deployment & scaling        | ML8s             |
| Drift monitoring            | ML8s             |
| Business validation         | ML Team          |

---

## Architecture Overview

ML8s operates across four planes:

### 1. Data Plane

* Versioned datasets in object storage (S3/Azure Blob/MinIO)
* Immutable snapshots
* Schema validation

---

### 2. Training Plane

* Kubernetes Job
* Optional Feature Engineering (Featuretools)
* AutoML optimization (FLAML)
* Deterministic data splits
* Evaluation + metrics
* Artifact storage
* Model registration

---

### 3. Serving Plane

* BentoML-based model packaging
* Kubernetes Deployment
* Horizontal Pod Autoscaling
* Canary or Blue-Green rollout
* Versioned model services

---

### 4. Monitoring Plane

* System metrics (latency, error rate)
* Prediction distribution monitoring
* Data drift detection (Evidently)
* Performance degradation tracking
* Alerting integration

---

## How It Works

### 1. Data Engineer publishes dataset

Example:

```
s3://ml-datasets/fraud/v3/
  ├── train.parquet
  ├── validation.parquet
  ├── schema.json
```

Immutable snapshot.

---

### 2. ML Engineer provides config

Example:

```yaml
dataset_uri: s3://ml-datasets/fraud/v3/
task: classification
target_column: is_fraud
metric: roc_auc

split:
  strategy: time
  time_column: transaction_time

feature_engineering:
  enabled: true
  max_depth: 2
  primitives: [sum, mean, count]

automl:
  engine: flaml
  time_budget: 600
  estimators: [lgbm, xgboost]
```

No Python code required.

---

### 3. Train

```
ml8s train --config s3://configs/fraud_v3.yaml
```

ML8s:

* Validates dataset
* Applies deterministic split
* Runs Featuretools (optional)
* Runs FLAML search
* Evaluates model
* Generates metrics + report
* Registers model candidate

---

### 4. Deploy

```
ml8s deploy --model-id fraud_v3_20260211
```

ML8s:

* Packages model with BentoML
* Updates Kubernetes Deployment
* Executes rollout strategy
* Enables monitoring
* Supports rollback

---

## Supported Workloads

ML8s is optimized for classical tabular ML:

* Fraud detection
* Churn prediction
* Credit risk scoring
* Demand forecasting
* Dynamic pricing
* CTR prediction
* Ranking models

Not designed for:

* Deep learning research
* Image or large NLP training
* Custom experimental pipelines

---

## Core Capabilities

### Deterministic Training

* Immutable datasets
* Logged hyperparameters
* Fixed seeds
* Full metadata tracking

### Automated Evaluation

* Required metric validation
* Classification/regression support
* Stored evaluation artifacts
* Reproducible splits

### Drift Detection

* Feature drift monitoring
* Prediction drift monitoring
* Scheduled evaluation jobs

### Safe Promotion

* Candidate → Production lifecycle
* Optional approval gates
* Canary rollout support
* Automatic rollback capability

---

## Model Lifecycle

```
DATASET PUBLISHED
        ↓
TRAIN (Candidate)
        ↓
EVALUATE
        ↓
PROMOTE
        ↓
PRODUCTION
        ↓
MONITOR
        ↓
RETRAIN (if needed)
```

All states tracked.

---

## Configuration-Driven, Not Code-Driven

ML8s eliminates notebook-to-production friction.

Users do not:

* Write Dockerfiles
* Build containers
* Define Kubernetes manifests
* Configure autoscaling
* Implement drift pipelines

They only define configuration.

---

## Technology Stack

* Kubernetes (AKS / EKS / k3s compatible)
* FLAML (AutoML engine)
* Featuretools (optional feature engineering)
* BentoML (model packaging & serving)
* Evidently (monitoring & drift detection)
* Object storage (S3/Azure Blob/MinIO)
* Prometheus + Grafana (metrics)

---

## Why ML8s

Without ML8s:

* Every team builds custom pipelines.
* Deployment is inconsistent.
* Reproducibility is weak.
* Monitoring is fragmented.

With ML8s:

* Standardized ML lifecycle
* Infrastructure abstraction
* Deterministic behavior
* Governance by design
* Faster productionization

---

## Non-Goals

ML8s is not:

* A notebook replacement
* A research platform
* A deep learning orchestration system
* A fully autonomous AI engine

It is a production platform for structured ML systems.

---

## Future Roadmap

* Multi-tenant namespaces
* Policy-driven auto-promotion
* Feature store integration
* Model registry UI
* Lineage tracking
* Cost-aware retraining triggers

---

## Summary

ML8s provides:

* Train with one command
* Deploy with one command
* Monitor continuously
* Govern safely
* No Kubernetes expertise required

It transforms classical ML from ad hoc workflows into a reliable infrastructure capability.

---



