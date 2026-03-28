#!/bin/sh
# agent-devtools installer
# Usage: curl -fsSL https://raw.githubusercontent.com/ohah/agent-devtools/main/install.sh | sh
set -e

REPO="ohah/agent-devtools"
INSTALL_DIR="/usr/local/bin"
BINARY_NAME="agent-devtools"

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "$OS" in
  darwin) PLATFORM="darwin" ;;
  linux)  PLATFORM="linux" ;;
  *)      echo "Unsupported OS: $OS"; exit 1 ;;
esac

case "$ARCH" in
  x86_64|amd64)  ARCH_NAME="x64" ;;
  arm64|aarch64) ARCH_NAME="arm64" ;;
  *)             echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

BINARY="${BINARY_NAME}-${PLATFORM}-${ARCH_NAME}"

# Get latest version
VERSION=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | sed 's/.*"tag_name": "//;s/".*//')

if [ -z "$VERSION" ]; then
  echo "Failed to fetch latest version"
  exit 1
fi

URL="https://github.com/${REPO}/releases/download/${VERSION}/${BINARY}"

echo "Installing ${BINARY_NAME} ${VERSION} (${PLATFORM}-${ARCH_NAME})..."
echo "Downloading from ${URL}"

# Download
TMP=$(mktemp)
curl -fsSL "$URL" -o "$TMP"

if [ ! -s "$TMP" ]; then
  echo "Download failed"
  rm -f "$TMP"
  exit 1
fi

# Install
chmod +x "$TMP"

if [ -w "$INSTALL_DIR" ]; then
  mv "$TMP" "${INSTALL_DIR}/${BINARY_NAME}"
else
  echo "Need sudo to install to ${INSTALL_DIR}"
  sudo mv "$TMP" "${INSTALL_DIR}/${BINARY_NAME}"
fi

echo ""
echo "✓ ${BINARY_NAME} ${VERSION} installed to ${INSTALL_DIR}/${BINARY_NAME}"
echo ""
echo "Get started:"
echo "  ${BINARY_NAME} open https://example.com"
echo "  ${BINARY_NAME} snapshot -i"
echo ""
echo "Install skill for AI agents:"
echo "  npx skills add ${REPO} --skill ${BINARY_NAME}"
