#!/usr/bin/env bash
set -Eeuo pipefail

# Raspberry Pi 5 — CYW43455 CLM installer
# Downloads Infineon CLM, validates it, backs up the old one
# and atomically replaces the active CLM file.

URL="https://github.com/Infineon/ifx-linux-firmware/raw/refs/heads/master/firmware/cyfmac43455-sdio.clm_blob"

TARGET="/usr/lib/firmware/cypress/cyfmac43455-sdio.clm_blob.zst"
BACKUP_DIR="/root/wifi-clm-backup"

log()  { echo "[INFO] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

# Root check
[[ "$EUID" -eq 0 ]] || fail "Run with sudo: sudo bash $0"

# Raspberry Pi 5 firmware link check
PI_LINK="/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.clm_blob.zst"

[[ -L "$PI_LINK" ]] || fail "Raspberry Pi 5 CLM firmware link not found"

LINK_TARGET="$(readlink -f "$PI_LINK")"
[[ "$LINK_TARGET" == "$TARGET" ]] ||
    fail "Unexpected CLM target: $LINK_TARGET"

# Install dependencies if necessary
MISSING=()

command -v curl >/dev/null || MISSING+=(curl)
command -v zstd >/dev/null || MISSING+=(zstd)

if ((${#MISSING[@]})); then
    log "Installing dependencies: ${MISSING[*]}"
    apt-get update
    apt-get install -y "${MISSING[@]}"
fi

command -v curl >/dev/null || fail "curl is unavailable"
command -v zstd >/dev/null || fail "zstd is unavailable"

# Check current CLM
[[ -f "$TARGET" ]] || fail "Current CLM not found: $TARGET"
[[ ! -L "$TARGET" ]] || fail "Target is a symlink; refusing to replace it"

zstd -t "$TARGET" >/dev/null ||
    fail "Current CLM archive is damaged"

# Temporary directory
WORKDIR="$(mktemp -d)"
TMP="${TARGET}.tmp.$$"

cleanup() {
    rm -rf "$WORKDIR"
    rm -f "$TMP"
}
trap cleanup EXIT

RAW="$WORKDIR/cyfmac43455-sdio.clm_blob"

# Download
log "Downloading Infineon CLM..."

curl --proto '=https' --tlsv1.2 -fL \
    --retry 3 \
    "$URL" \
    -o "$RAW" ||
    fail "CLM download failed"

[[ -s "$RAW" ]] || fail "Downloaded file is empty"

# Basic sanity check
SIZE="$(stat -c%s "$RAW")"
(( SIZE >= 1000 && SIZE <= 1000000 )) ||
    fail "Unexpected CLM file size: $SIZE bytes"

log "Downloaded file size: $SIZE bytes"
log "Source SHA256:"
sha256sum "$RAW"

# Compress
log "Compressing CLM..."

zstd -19 -f "$RAW" -o "$TMP" >/dev/null ||
    fail "Compression failed"

# Verify archive
zstd -t "$TMP" >/dev/null ||
    fail "Compressed CLM verification failed"

# Verify decompressed content
cmp -s "$RAW" <(zstd -dc "$TMP") ||
    fail "CLM content verification failed"

NEW_HASH="$(sha256sum "$TMP" | awk '{print $1}')"
OLD_HASH="$(sha256sum "$TARGET" | awk '{print $1}')"

echo
echo "Current CLM SHA256: $OLD_HASH"
echo "New CLM SHA256:     $NEW_HASH"
echo
echo "WARNING:"
echo "This is a generic Infineon CLM file."
echo "Its regulatory settings may not be suitable for every country."
echo "Check that its use complies with local radio regulations."
echo

read -r -p "Replace current CLM? Type YES to continue: " answer
[[ "$answer" == "YES" ]] || fail "Cancelled"

# Backup
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

BACKUP="$BACKUP_DIR/clm_blob-$(date +%Y%m%d-%H%M%S).zst"

cp -a "$TARGET" "$BACKUP"
log "Backup created: $BACKUP"

# Preserve permissions
chown --reference="$TARGET" "$TMP"
chmod --reference="$TARGET" "$TMP"

# Atomic replacement
mv -f "$TMP" "$TARGET"

# Final verification
zstd -t "$TARGET" >/dev/null ||
    fail "Installed CLM verification failed"

FINAL_HASH="$(sha256sum "$TARGET" | awk '{print $1}')"

[[ "$FINAL_HASH" == "$NEW_HASH" ]] ||
    fail "Installed checksum mismatch"

log "CLM successfully installed"
log "SHA256: $FINAL_HASH"
log "Backup: $BACKUP"

echo
echo "Reboot required to load the new CLM:"
echo "sudo reboot"
