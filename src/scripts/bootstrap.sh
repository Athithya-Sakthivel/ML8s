#!/usr/bin/env bash 
KUBECTL_VERSION="v1.28.5"
HELM_VERSION="v3.17.2"
YQ_VERSION="4.35.1"
PULUMI_VERSION="3.214.1"
# AWS CLI is now installed unpinned (latest). Do not rely on a pinned AWSCLI_VERSION variable.
PYTHON_PKGS=(
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

# kubectl
if ! version_contains kubectl "${KUBECTL_VERSION}"; then
  echo "Installing kubectl ${KUBECTL_VERSION}..."
  TMP_DIR="$(mktemp -d)"
  KUBECTL_BIN="${TMP_DIR}/kubectl"
  download "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "$KUBECTL_BIN"
  chmod +x "$KUBECTL_BIN"
  install_binary "$KUBECTL_BIN" kubectl
  rm -f "$KUBECTL_BIN"
fi

# helm
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

# yq
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

# AWS CLI (install latest unpinned)
# Use the generic AWS installer URL so we always get the latest unpinned release.
echo "Installing or updating AWS CLI to latest..."
TMP_DIR="$(mktemp -d)"
AWS_ZIP="${TMP_DIR}/awscliv2.zip"

# map ASSET_ARCH to AWS download arch token
case "$ASSET_ARCH" in
  amd64) AWS_ARCH="x86_64" ;;
  arm64) AWS_ARCH="aarch64" ;;
  *) AWS_ARCH="x86_64" ;;
esac

AWS_URL="https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip"

if ! download "$AWS_URL" "$AWS_ZIP"; then
  echo "Failed to download AWS CLI from $AWS_URL" >&2
  rm -rf "$TMP_DIR"
  exit 1
fi

unzip -q "$AWS_ZIP" -d "$TMP_DIR"
if [[ -x "${TMP_DIR}/aws/install" ]]; then
  # Try update first to upgrade existing installs; if that fails, try a plain install
  sudo "${TMP_DIR}/aws/install" --update || sudo "${TMP_DIR}/aws/install"
else
  echo "AWS installer not found or not executable in archive." >&2
  rm -rf "$TMP_DIR"
  exit 1
fi
rm -rf "$TMP_DIR"

# Verify installation succeeded
if ! command -v aws >/dev/null 2>&1; then
  echo "aws: command not found after installation." >&2
  exit 1
fi
echo "Installed AWS CLI version:"
aws --version 2>&1 || true

# Pulumi
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

# Python venv and packages
if [[ ! -d "$BOOTSTRAP_VENV" ]]; then
  echo "Creating Python venv at $BOOTSTRAP_VENV..."
  python3 -m venv "$BOOTSTRAP_VENV"
fi
echo "Upgrading pip/tools and installing Python packages into venv..."
"$BOOTSTRAP_VENV/bin/python" -m pip install --upgrade pip setuptools wheel --disable-pip-version-check
"$BOOTSTRAP_VENV/bin/python" -m pip install --no-cache-dir --upgrade "${PYTHON_PKGS[@]}"

PROFILE_FILE="${HOME}/.profile"

clear
echo "Bootstrap completed successfully."

# show key tool versions
command -v kubectl >/dev/null 2>&1 && kubectl version --client 2>&1 || echo "kubectl: not found or failed to query version"
command -v helm >/dev/null 2>&1 && helm version --short 2>&1 || echo "helm: not found or failed to query version"
command -v yq >/dev/null 2>&1 && yq --version || echo "yq: not found"
command -v pulumi >/dev/null 2>&1 && pulumi version || echo "pulumi: not found"
command -v aws >/dev/null 2>&1 && aws --version || echo "aws: not found"
