#!/usr/bin/env bash

KUBECTL_VERSION="v1.28.5"
HELM_VERSION="v3.17.2"
YQ_VERSION="4.35.1"
PULUMI_VERSION="3.214.1"
SOPS_VERSION="v3.11.0"
AWS_CLI_INSTALL="${AWS_CLI_INSTALL:-true}"
GCP_SDK_INSTALL="${GCP_SDK_INSTALL:-true}"
AZURE_CLI_INSTALL="${AZURE_CLI_INSTALL:-true}"
PYTHON_PKGS=(
  "jinja2==3.1.6"
  "ruamel.yaml==0.18.16"
  "pyyaml==6.0.3"
  "typing==3.7.4.3"
  "flytekit==1.16.14"
)
FLYTECTL_VERSION="${FLYTECTL_VERSION:-v0.8.18}"
FLUX_CLI_VERSION="${FLUX_CLI_VERSION:-v2.7.5}"
SOPS_VERSION="v3.11.0"

TMPDIR="$(mktemp -d)"
BOOTSTRAP_VENV="${HOME}/.bootstrap-venv"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

log(){ printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"; }

cleanup(){
  rm -rf "${TMPDIR}" 2>/dev/null || true
}
trap cleanup EXIT

require_sudo(){
  if ! sudo -n true 2>/dev/null; then
    sudo -v
  fi
}

download(){
  local url="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"
  curl -fSL --retry 5 --retry-delay 2 "$url" -o "$dest"
}

install_binary(){
  local src="$1" name="$2"
  sudo install -m 0755 "$src" "/usr/local/bin/$name"
}

version_contains(){
  local cmd="$1" expected="$2"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    return 1
  fi
  local out
  out="$("$cmd" --version 2>&1 || true)"
  : "${out:=$("$cmd" -v 2>&1 || true)}"
  : "${out:=$("$cmd" -V 2>&1 || true)}"
  if [[ -z "$out" ]]; then return 1; fi
  printf '%s' "$out" | grep -qF "$expected"
}

require_sudo

log "Updating apt and installing base packages"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends ca-certificates curl wget git jq unzip gnupg lsb-release python3 python3-venv python3-pip build-essential apt-transport-https file

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ASSET_ARCH="amd64" ; PULUMI_ASSET="linux-x64" ;;
  aarch64|arm64) ASSET_ARCH="arm64" ; PULUMI_ASSET="linux-arm64" ;;
  *) log "Unsupported architecture: $ARCH"; exit 1 ;;
esac

if ! version_contains kubectl "${KUBECTL_VERSION}"; then
  log "Installing kubectl ${KUBECTL_VERSION}"
  KUBECTL_BIN="${TMPDIR}/kubectl"
  download "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ASSET_ARCH}/kubectl" "${KUBECTL_BIN}"
  chmod +x "${KUBECTL_BIN}"
  install_binary "${KUBECTL_BIN}" kubectl
fi

if ! version_contains helm "${HELM_VERSION}"; then
  log "Installing helm ${HELM_VERSION}"
  HELM_TAR="${TMPDIR}/helm.tar.gz"
  download "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ASSET_ARCH}.tar.gz" "${HELM_TAR}"
  tar -xzf "${HELM_TAR}" -C "${TMPDIR}"
  install_binary "${TMPDIR}/linux-${ASSET_ARCH}/helm" helm
fi

if ! version_contains yq "${YQ_VERSION}"; then
  log "Installing yq ${YQ_VERSION}"
  YQ_BIN="${TMPDIR}/yq"
  download "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ASSET_ARCH}" "${YQ_BIN}"
  chmod +x "${YQ_BIN}"
  install_binary "${YQ_BIN}" yq
fi

if ! command -v pulumi >/dev/null 2>&1 || ! pulumi version 2>/dev/null | grep -q "v${PULUMI_VERSION}"; then
  log "Installing Pulumi ${PULUMI_VERSION}"
  PULUMI_TAR="${TMPDIR}/pulumi.tar.gz"
  PULUMI_URL="https://get.pulumi.com/releases/sdk/pulumi-v${PULUMI_VERSION}-${PULUMI_ASSET}.tar.gz"
  download "${PULUMI_URL}" "${PULUMI_TAR}"
  tar -xzf "${PULUMI_TAR}" -C "${TMPDIR}"
  sudo rm -rf /usr/local/pulumi || true
  sudo mv "${TMPDIR}/pulumi" /usr/local/pulumi
  sudo ln -sf /usr/local/pulumi/pulumi /usr/local/bin/pulumi
fi

if [ "${AWS_CLI_INSTALL}" = "true" ]; then
  log "Installing AWS CLI (latest installer)"
  AWS_ZIP="${TMPDIR}/awscliv2.zip"
  case "$ASSET_ARCH" in
    amd64) AWS_ARCH="x86_64" ;;
    arm64) AWS_ARCH="aarch64" ;;
    *) AWS_ARCH="x86_64" ;;
  esac
  AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"
  download "${AWS_URL}" "${AWS_ZIP}"
  unzip -q "${AWS_ZIP}" -d "${TMPDIR}"
  sudo "${TMPDIR}/aws/install" --update || sudo "${TMPDIR}/aws/install"
fi

if [ "${GCP_SDK_INSTALL}" = "true" ]; then
  log "Installing Google Cloud SDK via Google apt repository"
  sudo apt-get install -y --no-install-recommends apt-transport-https ca-certificates gnupg
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee /etc/apt/sources.list.d/google-cloud-sdk.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y google-cloud-cli
fi

if [ "${AZURE_CLI_INSTALL}" = "true" ]; then
  log "Installing Azure CLI (apt pinned)"
  sudo apt-get install -y --allow-downgrades --allow-change-held-packages azure-cli=2.61.0-1~jammy || true
  python3 -m pip install --upgrade --no-cache-dir azure-core==1.30.2 azure-identity==1.16.0 azure-mgmt-storage==21.2.1 azure-storage-blob==12.27.1
fi

SOPS_BIN="${TMPDIR}/sops"
log "Installing sops ${SOPS_VERSION}"
download "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.amd64" "${SOPS_BIN}"
chmod +x "${SOPS_BIN}"
install_binary "${SOPS_BIN}" sops

log "Setting up Python venv and packages"
if [[ ! -d "${BOOTSTRAP_VENV}" ]]; then
  python3 -m venv "${BOOTSTRAP_VENV}"
fi
"${BOOTSTRAP_VENV}/bin/python" -m pip install --upgrade pip setuptools wheel --disable-pip-version-check
"${BOOTSTRAP_VENV}/bin/python" -m pip install --no-cache-dir --upgrade "${PYTHON_PKGS[@]}"

log "Installing Flux CLI"
if ! version_contains flux "${FLUX_CLI_VERSION}"; then
  FLUX_INSTALL_SH="${TMPDIR}/flux_install.sh"
  download "https://fluxcd.io/install.sh" "${FLUX_INSTALL_SH}"
  sudo bash "${FLUX_INSTALL_SH}" >/dev/null 2>&1 || true
fi

log "Installing Flyte SDK and attempting to install flytectl (best-effort)"
if ! command -v flytectl >/dev/null 2>&1; then
  FLYTECTL_ARCHIVE="${TMPDIR}/flytectl${FLYTECTL_VERSION}.tar.gz"
  FLYTECTL_URL1="https://github.com/flyteorg/flytectl/releases/download/${FLYTECTL_VERSION}/flytectl_${FLYTECTL_VERSION}_linux_amd64.tar.gz"
  FLYTECTL_URL2="https://github.com/flyteorg/flytectl/releases/download/${FLYTECTL_VERSION}/flytectl-${FLYTECTL_VERSION}-linux-amd64.tar.gz"
  set +e
  download "${FLYTECTL_URL1}" "${FLYTECTL_ARCHIVE}" 2>/dev/null
  if [[ $? -ne 0 || ! -s "${FLYTECTL_ARCHIVE}" ]]; then
    download "${FLYTECTL_URL2}" "${FLYTECTL_ARCHIVE}" 2>/dev/null || true
  fi
  set -e
  if [[ -s "${FLYTECTL_ARCHIVE}" ]]; then
    tar -xzf "${FLYTECTL_ARCHIVE}" -C "${TMPDIR}"
    if [[ -x "${TMPDIR}/flytectl" ]]; then
      install_binary "${TMPDIR}/flytectl" flytectl
    fi
  else
    log "flytectl binary not found in expected release URLs; please install flytectl manually: https://github.com/flyteorg/flytectl/releases"
  fi
fi

clear
log "Verifying key tool versions"
kubectl version --client 2>&1 || log "kubectl check failed"
helm version --short 2>&1 || log "helm check failed"
yq --version || log "yq check failed"
pulumi version || log "pulumi check failed"
sops --version || log "sops check failed"
"${BOOTSTRAP_VENV}/bin/python" -m pip show flytekit >/dev/null 2>&1 || log "flytekit not present in venv"
if command -v flytectl >/dev/null 2>&1; then flytectl version || true; else log "flytectl not installed"; fi
if command -v flux >/dev/null 2>&1; then flux --version || true; else log "flux CLI not installed"; fi
if command -v gcloud >/dev/null 2>&1; then gcloud --version || log "gcloud check failed"; else log "gcloud not installed"; fi

log "Bootstrap finished. PATH additions (if any) and next steps:"
log " - Activate Python venv: source ${BOOTSTRAP_VENV}/bin/activate"
log " - Use 'flux' CLI to bootstrap GitOps or 'flytectl' to interact with Flyte control plane (if installed)"
log " - sops available at: $(command -v sops || echo '/usr/local/bin/sops')"

exit 0
