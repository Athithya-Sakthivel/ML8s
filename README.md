

```sh
export GIT_URL="https://github.com/<username>/<repo_name>.git" # Same name used when creating the private repo
export GIT_TOKEN="ghp_" # Create one with https://github.com/settings/tokens/new
make setup-flux
```

### STEP 1: Setup [Flyte(Kubeflow alternative)](https://flyte.org/kubeflow-alternative) after configuring artifact storage. StateDB is platform-managed via [CNPG](https://cloudnative-pg.io/docs/1.28/).
> If STORAGE_BACKEND not set, then default miniO will be used.

<details>
<summary>AWS (S3)</summary>

```bash
export ENV=dev
export STORAGE_BACKEND=s3
export S3_BUCKET=ml8s-flyte-dev
export S3_REGION=us-east-1
export S3_ACCESS_KEY_ID=YOUR_AWS_ACCESS_KEY_ID
export S3_SECRET_ACCESS_KEY=YOUR_AWS_SECRET_ACCESS_KEY
```

</details>

<details>
<summary>GCP (GCS)</summary>

```bash
export ENV=dev
export STORAGE_BACKEND=gcs
export GCS_BUCKET=ml8s-flyte-dev
export GCP_PROJECT_ID=my-gcp-project
export GCS_SERVICE_ACCOUNT_JSON_PATH=/absolute/path/to/sa-key.json
```

</details>

<details>
<summary>Azure (Blob)</summary>

```bash
export ENV=dev
export STORAGE_BACKEND=azure
export AZURE_CONTAINER=ml8s-flyte-dev
export AZURE_STORAGE_ACCOUNT=myazurestorageaccount
export AZURE_STORAGE_KEY=YOUR_STORAGE_ACCOUNT_KEY
```
</details>






























