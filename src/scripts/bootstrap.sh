#!/usr/bin/env bash
GO_VERSION="1.26.0"
KUBECTL_VERSION="v1.28.5"
HELM_VERSION="v3.17.2"
YQ_VERSION="4.35.1"
PULUMI_VERSION="3.214.1"
AZ_CLI_VERSION="2.61.0-1~jammy"
KUBEBUILDER_VERSION="4.11.1"
AWSCLI_VERSION="2.15.33"
PYTHON_PKGS=(
  "azure-core==1.30.2"
  "azure-identity==1.16.0"
  "azure-mgmt-storage==21.2.1"
  "azure-storage-blob==12.27.1"
  "jinja2==3.1.6"
  "ruamel.yaml==0.18.16"
  "pyyaml==6.0.3"
  "typing==3.7.4.3"
)
BOOTSTRAP_VENV="${HOME}/.bootstrap-venv"
DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
TMP_DIR=""
cleanup() {
  if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT
require_sudo() {
  if ! sudo -n true 2>/dev/null; then
    sudo -v
  fi
}
download() {
  local url="$1"; local dest="$2"
  mkdir -p "$(dirname "$dest")"
  if ! curl -fSL --retry 5 --retry-delay 2 "$url" -o "$dest"; then
    return 1
  fi
  if [[ ! -s "$dest" ]]; then
    echo "Download saved empty file: $url" >&2
    return 1
  fi
  return 0
}
install_binary() {
  local src="$1"; local name="$2"
  sudo install -m 0755 "$src" "/usr/local/bin/$name"
}
version_contains() {
  local cmd="$1"; local expected="$2"
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
echo "Updating apt and installing base packages..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  ca-certificates curl wget git jq unzip gnupg lsb-release \
  python3 python3-venv python3-pip build-essential apt-transport-https file
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) ASSET_ARCH="amd64" ; PULUMI_ASSET="linux-x64" ;;
  aarch64|arm64) ASSET_ARCH="arm64" ; PULUMI_ASSET="linux-arm64" ;;
  *) echo "Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
if ! version_contains go "go${GO_VERSION}"; then
  echo "Installing Go ${GO_VERSION}..."
  TMP_DIR="$(mktemp -d)"
  GO_TAR="${TMP_DIR}/go.tar.gz"
  URL="https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz"
  download "$URL" "$GO_TAR"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$GO_TAR"
  rm -f "$GO_TAR"
fi
export PATH="/usr/local/go/bin:$PATH"
if ! version_contains kubectl "${KUBECTL_VERSION}"; then
  echo "Installing kubectl ${KUBECTL_VERSION}..."
  TMP_DIR="$(mktemp -d)"
  KUBECTL_BIN="${TMP_DIR}/kubectl"
  download "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "$KUBECTL_BIN"
  chmod +x "$KUBECTL_BIN"
  install_binary "$KUBECTL_BIN" kubectl
  rm -f "$KUBECTL_BIN"
fi
if ! version_contains helm "${HELM_VERSION}"; then
  echo "Installing helm ${HELM_VERSION}..."
  TMP_DIR="$(mktemp -d)"
  HELM_TAR="${TMP_DIR}/helm.tar.gz"
  download "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" "$HELM_TAR"
  tar -xzf "$HELM_TAR" -C "$TMP_DIR"
  if [[ -x "${TMP_DIR}/linux-amd64/helm" ]]; then
    install_binary "${TMP_DIR}/linux-amd64/helm" helm
  else
    echo "helm binary not found in tarball" >&2
    exit 1
  fi
  rm -rf "$TMP_DIR"
fi
if ! version_contains yq "${YQ_VERSION}"; then
  echo "Installing yq ${YQ_VERSION}..."
  TMP_DIR="$(mktemp -d)"
  YQ_BIN="${TMP_DIR}/yq"
  YQ_URL="https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${ASSET_ARCH}"
  if ! download "$YQ_URL" "$YQ_BIN"; then
    echo "Failed to download yq from $YQ_URL" >&2
    exit 1
  fi
  if file "$YQ_BIN" 2>/dev/null | grep -q -E 'ELF|executable|Mach-O|PE32'; then
    chmod +x "$YQ_BIN"
    install_binary "$YQ_BIN" yq
  else
    echo "Downloaded yq binary is not valid (file check failed)" >&2
    exit 1
  fi
  rm -rf "$TMP_DIR"
fi
if ! version_contains az "azure-cli"; then
  echo "Installing Azure CLI..."
  sudo mkdir -p /etc/apt/keyrings
  curl -fSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
    | sudo tee /etc/apt/sources.list.d/azure-cli.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y --allow-downgrades "azure-cli=${AZ_CLI_VERSION}" || sudo apt-get install -y azure-cli
fi
if ! version_contains aws "aws-cli/"; then
  echo "Installing AWS CLI ${AWSCLI_VERSION}..."
  TMP_DIR="$(mktemp -d)"
  AWS_ZIP="${TMP_DIR}/awscliv2.zip"
  AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-${ASSET_ARCH}-${AWSCLI_VERSION}.zip"
  download "$AWS_URL" "$AWS_ZIP"
  unzip -q "$AWS_ZIP" -d "$TMP_DIR"
  sudo "${TMP_DIR}/aws/install" --update
  rm -rf "$TMP_DIR"
fi
if ! command -v pulumi >/dev/null 2>&1 || ! pulumi version 2>/dev/null | grep -q "v${PULUMI_VERSION}"; then
  echo "Installing Pulumi ${PULUMI_VERSION}..."
  TMP_DIR="$(mktemp -d)"
  PULUMI_TAR="${TMP_DIR}/pulumi.tar.gz"
  PULUMI_URL="https://get.pulumi.com/releases/sdk/pulumi-v${PULUMI_VERSION}-${PULUMI_ASSET}.tar.gz"
  if ! download "$PULUMI_URL" "$PULUMI_TAR"; then
    echo "Failed to download Pulumi from $PULUMI_URL" >&2
    exit 1
  fi
  tar -xzf "$PULUMI_TAR" -C "$TMP_DIR"
  if [[ -x "${TMP_DIR}/pulumi/pulumi" ]]; then
    sudo rm -rf /usr/local/pulumi
    sudo mv "${TMP_DIR}/pulumi" /usr/local/pulumi
    sudo ln -sf /usr/local/pulumi/pulumi /usr/local/bin/pulumi
  else
    echo "Pulumi binary not found after extraction" >&2
    exit 1
  fi
  rm -rf "$TMP_DIR"
fi
if ! version_contains kubebuilder "v${KUBEBUILDER_VERSION}"; then
  echo "Installing kubebuilder ${KUBEBUILDER_VERSION}..."
  TMP_DIR="$(mktemp -d)"
  KB_BIN="${TMP_DIR}/kubebuilder"
  KB_BIN_URL="https://github.com/kubernetes-sigs/kubebuilder/releases/download/v${KUBEBUILDER_VERSION}/kubebuilder_linux_${ASSET_ARCH}"
  if download "$KB_BIN_URL" "$KB_BIN"; then
    :
  else
    KB_TAR="${TMP_DIR}/kubebuilder.tar.gz"
    KB_TAR_URL="https://github.com/kubernetes-sigs/kubebuilder/releases/download/v${KUBEBUILDER_VERSION}/kubebuilder_${KUBEBUILDER_VERSION}_linux_${ASSET_ARCH}.tar.gz"
    if download "$KB_TAR_URL" "$KB_TAR"; then
      tar -xzf "$KB_TAR" -C "$TMP_DIR"
      if [[ -x "${TMP_DIR}/kubebuilder" ]]; then
        mv "${TMP_DIR}/kubebuilder" "$KB_BIN"
      elif [[ -x "${TMP_DIR}/bin/kubebuilder" ]]; then
        mv "${TMP_DIR}/bin/kubebuilder" "$KB_BIN"
      else
        echo "kubebuilder binary not found inside tarball" >&2
        exit 1
      fi
    else
      echo "Failed to download kubebuilder from both $KB_BIN_URL and $KB_TAR_URL" >&2
      exit 1
    fi
  fi
  if file "$KB_BIN" 2>/dev/null | grep -q ELF; then
    chmod +x "$KB_BIN"
    install_binary "$KB_BIN" kubebuilder
  else
    echo "Downloaded kubebuilder is not a valid ELF binary" >&2
    exit 1
  fi
  rm -rf "$TMP_DIR"
fi
if [[ ! -d "$BOOTSTRAP_VENV" ]]; then
  echo "Creating Python venv at $BOOTSTRAP_VENV..."
  python3 -m venv "$BOOTSTRAP_VENV"
fi
echo "Upgrading pip/tools and installing Python packages into venv..."
"$BOOTSTRAP_VENV/bin/python" -m pip install --upgrade pip setuptools wheel --disable-pip-version-check
"$BOOTSTRAP_VENV/bin/python" -m pip install --no-cache-dir --upgrade "${PYTHON_PKGS[@]}"
PROFILE_FILE="${HOME}/.profile"
if ! grep -q '/usr/local/go/bin' "$PROFILE_FILE" 2>/dev/null; then
  printf '\nexport PATH="/usr/local/go/bin:$PATH"\n' >> "$PROFILE_FILE"
fi
clear
echo "Bootstrap completed successfully."
command -v go >/dev/null 2>&1 && go version || echo "go: not found"
command -v kubectl >/dev/null 2>&1 && kubectl version --client 2>&1 || echo "kubectl: not found or failed to query version"
command -v helm >/dev/null 2>&1 && helm version --short 2>&1 || echo "helm: not found or failed to query version"
command -v yq >/dev/null 2>&1 && yq --version || echo "yq: not found"
command -v pulumi >/dev/null 2>&1 && pulumi version || echo "pulumi: not found"
command -v kubebuilder >/dev/null 2>&1 && kubebuilder version || echo "kubebuilder: not found"
command -v az >/dev/null 2>&1 && az --version 2>/dev/null | head -n 1 || echo "az: not found"
command -v aws >/dev/null 2>&1 && aws --version || echo "aws: not found"
"$BOOTSTRAP_VENV/bin/python" -m pip show azure-core >/dev/null 2>&1 && \
  "$BOOTSTRAP_VENV/bin/python" -m pip show azure-core | grep -E 'Version:|Name:' || \
  echo "azure-core: not installed in venv"
