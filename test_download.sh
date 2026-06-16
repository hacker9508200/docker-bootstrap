#!/bin/bash
set -e

# Test script to diagnose "invalid tar header" in restricted envs
# Downloads a single image layer and reports what actually came back.

echo "============================================"
echo " Docker Offline Download Diagnostic"
echo "============================================"

for cmd in curl jq; do
  if ! command -v $cmd &>/dev/null; then
    echo "ERROR: '$cmd' not found."
    exit 1
  fi
done

IMAGE="${1:-library/alpine}"
TAG="${2:-latest}"
OUT_DIR="${3:-/tmp/docker-test}"
mkdir -p "$OUT_DIR"

echo ""
echo "Image: $IMAGE:$TAG"
echo ""

# 1. Get auth token
echo "[1/4] Getting auth token..."
TOKEN=$(curl -fsSL "https://auth.docker.io/token?service=registry.docker.io&scope=repository:$IMAGE:pull" | jq -r '.token')
echo "  Token OK"

# 2. Fetch manifest
echo "[2/4] Fetching manifest..."
MANIFEST=$(curl -fsSL --compressed \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  "https://registry-1.docker.io/v2/$IMAGE/manifests/$TAG")
SCHEMA=$(echo "$MANIFEST" | jq -r '.schemaVersion')
echo "  Schema: $SCHEMA"

# Handle multi-arch index
MEDIA=$(echo "$MANIFEST" | jq -r '.mediaType // ""')
case "$MEDIA" in
  application/vnd.oci.image.index.v1+json | application/vnd.docker.distribution.manifest.list.v2+json)
    echo "  Multi-arch manifest, resolving for $(uname -m)..."
    ARCH=$(uname -m)
    case "$ARCH" in x86_64) ARCH="amd64" ;; aarch64) ARCH="arm64" ;; esac
    DIGEST=$(echo "$MANIFEST" | jq -r --arg a "$ARCH" '.manifests[] | select(.platform.architecture==$a) | .digest' | head -1)
    MANIFEST=$(curl -fsSL --compressed \
      -H "Authorization: Bearer $TOKEN" \
      -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
      -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
      "https://registry-1.docker.io/v2/$IMAGE/manifests/$DIGEST")
    echo "  Resolved to single manifest"
    ;;
esac

# 3. List layers and config
CONFIG_DIGEST=$(echo "$MANIFEST" | jq -r '.config.digest')
echo "  Config: ${CONFIG_DIGEST:0:24}..."

LAYERS=$(echo "$MANIFEST" | jq -r '.layers | length')
echo "  Layers: $LAYERS"
echo ""

# 4. Download config blob
echo "[3/4] Downloading config blob..."
echo "  URL: https://registry-1.docker.io/v2/$IMAGE/blobs/$CONFIG_DIGEST"
curl -fsSL --compressed -H "Authorization: Bearer $TOKEN" \
  "https://registry-1.docker.io/v2/$IMAGE/blobs/$CONFIG_DIGEST" \
  -o "$OUT_DIR/config.json"
echo "  File type: $(file "$OUT_DIR/config.json")"
echo ""

# 5. Download first layer with .blob extension, and .tar extension for comparison
echo "[4/4] Downloading first layer..."
LAYER_DIGEST=$(echo "$MANIFEST" | jq -r '.layers[0].digest')
LAYER_MEDIA=$(echo "$MANIFEST" | jq -r '.layers[0].mediaType')
echo "  MediaType: $LAYER_MEDIA"
echo "  Digest: ${LAYER_DIGEST:0:24}..."

echo ""
echo "  --- Download as layer.blob ---"
curl -L -# --compressed -H "Authorization: Bearer $TOKEN" \
  "https://registry-1.docker.io/v2/$IMAGE/blobs/$LAYER_DIGEST" \
  -o "$OUT_DIR/layer.blob"
file "$OUT_DIR/layer.blob"
SIZE=$(stat -c%s "$OUT_DIR/layer.blob" 2>/dev/null || stat -f%z "$OUT_DIR/layer.blob" 2>/dev/null)
echo "  Size: $SIZE bytes"
echo ""

echo "  --- Download as layer.raw (no extension) ---"
curl -L -# --compressed -H "Authorization: Bearer $TOKEN" \
  "https://registry-1.docker.io/v2/$IMAGE/blobs/$LAYER_DIGEST" \
  -o "$OUT_DIR/layer.raw"
file "$OUT_DIR/layer.raw"
SIZE2=$(stat -c%s "$OUT_DIR/layer.raw" 2>/dev/null || stat -f%z "$OUT_DIR/layer.raw" 2>/dev/null)
echo "  Size: $SIZE2 bytes"
echo ""

# Compare
if cmp -s "$OUT_DIR/layer.blob" "$OUT_DIR/layer.raw"; then
  echo "  ✅ Both downloads are identical (extension makes no difference)"
else
  echo "  ❌ Files differ! Extension IS affecting the download."
  echo "     Your proxy/firewall modifies content based on filename extension."
fi

echo ""
echo "--- HTTP headers for layer download ---"
curl -L -s -D- --compressed -H "Authorization: Bearer $TOKEN" \
  "https://registry-1.docker.io/v2/$IMAGE/blobs/$LAYER_DIGEST" \
  -o /dev/null 2>&1 | head -20

echo ""
echo "============================================"
echo " Diagnostic complete"
echo "============================================"
echo ""
echo "Check the output above:"
echo "  - 'gzip compressed data'  → download OK, issue is in docker load"
echo "  - 'HTML document' or text → proxy returning error page"
echo "  - Files differ by extension → proxy filters by filename extension"
