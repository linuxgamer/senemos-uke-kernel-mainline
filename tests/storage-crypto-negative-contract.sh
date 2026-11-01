#!/usr/bin/env bash
set -Eeuo pipefail
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d)
trap 'find "$work" -depth -delete' EXIT
bash "$owner/tests/storage-crypto-contract.sh"
for symbol in EXT4_FS F2FS_FS XFS_FS BTRFS_FS DM_CRYPT DM_INLINECRYPT \
    FS_ENCRYPTION BLK_INLINE_ENCRYPTION_FALLBACK CRYPTO_AES_ARM64_CE_BLK \
    CRYPTO_XTS QCOM_INLINE_CRYPTO_ENGINE SCSI_UFS_CRYPTO; do
    sed "s/^CONFIG_$symbol=.*/# CONFIG_$symbol is not set/" \
        "$owner/packaging/native/native.config" > "$work/config"
    if bash "$owner/tests/storage-crypto-contract.sh" "$work/config" > "$work/result" 2>&1; then
        printf 'Missing prerequisite was accepted: %s\n' "$symbol" >&2; exit 1;
    fi
    grep -Fq "$symbol" "$work/result"
done
printf 'Twelve missing-filesystem/crypto prerequisite controls: passed\n'
