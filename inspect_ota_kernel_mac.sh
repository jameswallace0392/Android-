#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C   # treat the image as raw bytes, not UTF-8

# Usage:
#   ./inspect_ota_kernel_mac.sh                 # download the default rango OTA below
#   ./inspect_ota_kernel_mac.sh <url>           # download another full OTA
#   ./inspect_ota_kernel_mac.sh <path/ota.zip>  # use a zip you already have
#
# Full OTA list and SHA-256 hashes: https://developers.google.com/android/ota#rango

# --- 0. Pick / download the OTA ---
DEFAULT_OTA_URL="https://dl.google.com/dl/android/aosp/rango-ota-cp3a.261005.005-4d0f56f9.zip"

# Paste the full SHA-256 from the Google OTA page here (or pass OTA_SHA256=... in the
# environment). If left empty, only the 8-char hash prefix in the filename is checked.
OTA_SHA256="${OTA_SHA256:-}"

DOWNLOAD_DIR="${DOWNLOAD_DIR:-$HOME/Downloads}"
SOURCE="${1:-$DEFAULT_OTA_URL}"

if [[ "$SOURCE" =~ ^https?:// ]]; then
    OTA_ZIP="$DOWNLOAD_DIR/$(basename "$SOURCE")"
    mkdir -p "$DOWNLOAD_DIR"
    if [ -f "$OTA_ZIP" ]; then
        echo "[*] Found existing $OTA_ZIP; resuming/verifying download..."
    else
        echo "[*] Downloading $SOURCE"
    fi
    # -f: fail on HTTP errors, -L: follow redirects, -C -: resume partial downloads
    curl -fL --retry 3 -C - -o "$OTA_ZIP" "$SOURCE"
else
    OTA_ZIP="$SOURCE"
fi

if [ ! -f "$OTA_ZIP" ]; then
    echo "Error: File '$OTA_ZIP' not found."
    exit 1
fi

# --- 0b. Verify SHA-256 ---
echo "[*] Computing SHA-256 of $(basename "$OTA_ZIP") (this takes a moment)..."
ACTUAL_SHA256="$(shasum -a 256 "$OTA_ZIP" | awk '{print $1}')"
echo "    $ACTUAL_SHA256"

if [ -n "$OTA_SHA256" ]; then
    EXPECTED="$(echo "$OTA_SHA256" | tr 'A-F' 'a-f')"
    if [ "$ACTUAL_SHA256" != "$EXPECTED" ]; then
        echo "Error: SHA-256 mismatch!"
        echo "  expected: $EXPECTED"
        echo "  actual:   $ACTUAL_SHA256"
        echo "Delete '$OTA_ZIP' and re-download."
        exit 1
    fi
    echo "[✓] Full SHA-256 matches."
else
    # Google OTA filenames end in -<first 8 hex chars of the SHA-256>.zip
    PREFIX="$(basename "$OTA_ZIP" .zip | ggrep -oE '[0-9a-f]{8}$' 2>/dev/null \
              || basename "$OTA_ZIP" .zip | grep -oE '[0-9a-f]{8}$' || true)"
    if [ -n "$PREFIX" ]; then
        if [ "${ACTUAL_SHA256:0:8}" != "$PREFIX" ]; then
            echo "Error: SHA-256 does not start with '$PREFIX' from the filename."
            echo "Delete '$OTA_ZIP' and re-download."
            exit 1
        fi
        echo "[✓] Hash prefix '$PREFIX' matches filename."
        echo "[!] For full verification, set OTA_SHA256 to the hash from the Google OTA page."
    else
        echo "[!] No expected hash available; skipping verification."
    fi
fi

# --- 1. Check for Homebrew ---
if ! command -v brew &>/dev/null; then
    echo "Error: Homebrew is not installed. Install it from https://brew.sh first."
    exit 1
fi

# --- 2. Install required Homebrew packages ---
MISSING_DEPS=()
command -v payload-dumper-go &>/dev/null || MISSING_DEPS+=(payload-dumper-go)
command -v lz4 &>/dev/null               || MISSING_DEPS+=(lz4)
command -v ggrep &>/dev/null             || MISSING_DEPS+=(grep)

if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    echo "[*] Installing missing tools via Homebrew: ${MISSING_DEPS[*]}..."
    brew install "${MISSING_DEPS[@]}"
fi

# --- 3. Extract payload.bin & boot.img ---
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[*] Extracting payload.bin from $OTA_ZIP..."
if ! unzip -q "$OTA_ZIP" payload.bin -d "$WORKDIR"; then
    echo "Error: payload.bin not found. Is this a full (not incremental) OTA?"
    exit 1
fi

echo "[*] Dumping boot.img using payload-dumper-go..."
payload-dumper-go -p boot -o "$WORKDIR/extracted" "$WORKDIR/payload.bin" >/dev/null

BOOT_IMG="$WORKDIR/extracted/boot.img"
if [ ! -f "$BOOT_IMG" ]; then
    echo "Error: Failed to extract boot.img"
    exit 1
fi

# --- 4. Inspect kernel version ---
BANNER_RE='Linux version [0-9]+\.[0-9]+'
MAX_TRIES=5   # how many candidate offsets to try per magic number

# Read a stream on stdin and print the first kernel banner, if any.
# "|| true" stops SIGPIPE / no-match from failing under pipefail.
scan() { strings -a | ggrep -E -m 1 "$BANNER_RE" || true; }

# Print the banner and stop if one was found.
report() {
    if [ -n "$1" ]; then
        echo ""
        echo "=== Kernel Version Found in boot.img ==="
        echo "$1"
        exit 0
    fi
}

# Byte offsets (0-based) of a magic sequence in the boot image.
offsets() { ggrep -abo "$1" "$BOOT_IMG" 2>/dev/null | cut -d: -f1 | head -n "$MAX_TRIES" || true; }

# 4a. Uncompressed kernel
report "$(scan < "$BOOT_IMG")"

echo "[*] Kernel payload is compressed; scanning compressed streams..."

# 4b. GZIP (1f 8b 08)
for off in $(offsets $'\x1f\x8b\x08'); do
    report "$(tail -c +$((off + 1)) "$BOOT_IMG" | { gzip -dc 2>/dev/null || true; } | scan)"
done

# 4c. LZ4 legacy (02 21 4c 18) and frame (04 22 4d 18)
for MAGIC in $'\x02\x21\x4c\x18' $'\x04\x22\x4d\x18'; do
    for off in $(offsets "$MAGIC"); do
        report "$(tail -c +$((off + 1)) "$BOOT_IMG" | { lz4 -d -q -c 2>/dev/null || true; } | scan)"
    done
done

echo "[!] Could not locate kernel banner string."
exit 1
