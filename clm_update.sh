#!/usr/bin/env bash
set -Eeuo pipefail

# Raspberry Pi 5 — CYW43455 CLM installer
# Idempotent: does nothing if the same CLM is already installed.

URL="https://github.com/Infineon/ifx-linux-firmware/raw/refs/heads/master/firmware/cyfmac43455-sdio.clm_blob"

TARGET="/usr/lib/firmware/cypress/cyfmac43455-sdio.clm_blob.zst"
PI_LINK="/usr/lib/firmware/brcm/brcmfmac43455-sdio.raspberrypi,5-model-b.clm_blob.zst"
BACKUP_DIR="/root/wifi-clm-backup"

log()  { echo "[INFO] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

# --------------------------------------------------
# 1. Root check
# --------------------------------------------------

[[ "$EUID" -eq 0 ]] || fail "Run with sudo: sudo bash $0"

# --------------------------------------------------
# 2. Check Raspberry Pi 5 firmware layout
# --------------------------------------------------

[[ -L "$PI_LINK" ]] || fail "Raspberry Pi 5 CLM link not found"

LINK_TARGET="$(readlink -f "$PI_LINK")"

[[ "$LINK_TARGET" == "$TARGET" ]] ||
    fail "Unexpected CLM target: $LINK_TARGET"

[[ -f "$TARGET" ]] ||
    fail "Current CLM not found: $TARGET"

[[ ! -L "$TARGET" ]] ||
    fail "Target is a symlink; refusing to replace it"

# --------------------------------------------------
# 3. Install dependencies
# --------------------------------------------------

MISSING=()

command -v curl >/dev/null || MISSING+=(curl)
command -v zstd >/dev/null || MISSING+=(zstd)

if ((${#MISSING[@]})); then
    log "Installing dependencies: ${MISSING[*]}"
    apt-get update
    apt-get install -y "${MISSING[@]}"
fi

command -v sha256sum >/dev/null ||
    fail "sha256sum is missing"

# --------------------------------------------------
# 4. Check current CLM
# --------------------------------------------------

zstd -t "$TARGET" >/dev/null ||
    fail "Current CLM archive is damaged"

OLD_HASH="$(sha256sum "$TARGET" | awk '{print $1}')"

log "Current CLM SHA256: $OLD_HASH"

# --------------------------------------------------
# 5. Prepare temporary directory
# --------------------------------------------------

WORKDIR="$(mktemp -d)"
TMP="${TARGET}.tmp.$$"

cleanup() {
    rm -rf "$WORKDIR"
    rm -f "$TMP"
}
trap cleanup EXIT

RAW="$WORKDIR/cyfmac43455-sdio.clm_blob"

# --------------------------------------------------
# 6. Download CLM
# --------------------------------------------------

log "Downloading Infineon CLM..."

curl --proto '=https' --tlsv1.2 \
    -fL --retry 3 \
    "$URL" \
    -o "$RAW" ||
    fail "CLM download failed"

[[ -s "$RAW" ]] ||
    fail "Downloaded file is empty"

SIZE="$(stat -c%s "$RAW")"

(( SIZE >= 1000 && SIZE <= 1000000 )) ||
    fail "Unexpected CLM file size: $SIZE bytes"

log "Downloaded size: $SIZE bytes"

# --------------------------------------------------
# 7. Compress and validate
# --------------------------------------------------

log "Compressing CLM..."

zstd -19 -f "$RAW" -o "$TMP" >/dev/null ||
    fail "Compression failed"

zstd -t "$TMP" >/dev/null ||
    fail "Compressed CLM verification failed"

cmp -s "$RAW" <(zstd -dc "$TMP") ||
    fail "CLM content verification failed"

NEW_HASH="$(sha256sum "$TMP" | awk '{print $1}')"

log "Downloaded CLM SHA256: $NEW_HASH"

# --------------------------------------------------
# 8. Idempotency check
# --------------------------------------------------

if [[ "$NEW_HASH" == "$OLD_HASH" ]]; then
    log "The same CLM is already installed."
    log "Nothing to do."
    exit 0
fi

# --------------------------------------------------
# 9. Confirmation
# --------------------------------------------------

echo
echo "Current CLM: $OLD_HASH"
echo "New CLM:     $NEW_HASH"
echo
echo "WARNING:"
echo "This is a generic Infineon CLM file."
echo "Its regulatory settings may not be suitable for every country."
echo "Verify compliance with local radio regulations."
echo

read -r -p "Replace current CLM? Type YES to continue: " answer

[[ "$answer" == "YES" ]] ||
    fail "Cancelled"

# --------------------------------------------------
# 10. Backup
# --------------------------------------------------

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

BACKUP="$BACKUP_DIR/clm_blob-$(date +%Y%m%d-%H%M%S).zst"

cp -a "$TARGET" "$BACKUP"

log "Backup created: $BACKUP"

# --------------------------------------------------
# 11. Atomic replacement
# --------------------------------------------------

chown --reference="$TARGET" "$TMP"
chmod --reference="$TARGET" "$TMP"

mv -f "$TMP" "$TARGET"

# --------------------------------------------------
# 12. Final verification
# --------------------------------------------------

zstd -t "$TARGET" >/dev/null ||
    fail "Installed CLM verification failed"

FINAL_HASH="$(sha256sum "$TARGET" | awk '{print $1}')"

[[ "$FINAL_HASH" == "$NEW_HASH" ]] ||
    fail "Installed checksum mismatch"

log "CLM successfully installed"
log "SHA256: $FINAL_HASH"
log "Backup: $BACKUP"

echo
echo "Reboot required:"
echo "sudo reboot"
