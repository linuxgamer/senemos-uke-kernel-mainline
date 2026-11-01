#!/usr/bin/env bash
# Configuration prerequisites only; never opens a device or loads a key.
set -Eeuo pipefail
owner=$(cd -- "$(dirname -- "$0")/.." && pwd)
config=${1:-$owner/packaging/native/native.config}
for symbol in EXT4_FS F2FS_FS XFS_FS BTRFS_FS BLK_DEV_DM DM_CRYPT DM_INLINECRYPT \
    FS_ENCRYPTION FS_ENCRYPTION_ALGS FS_ENCRYPTION_INLINE_CRYPT \
    BLK_INLINE_ENCRYPTION BLK_INLINE_ENCRYPTION_FALLBACK SCSI_UFS_CRYPTO \
    SCSI_UFS_HWMON CRYPTO_AES_ARM64_CE_BLK CRYPTO_XTS FS_VERITY; do
    grep -Fxq "CONFIG_$symbol=y" "$config" || {
        printf 'Missing encrypted-storage prerequisite: %s\n' "$symbol" >&2; exit 1;
    }
done
for symbol in QCOM_INLINE_CRYPTO_ENGINE DM_INTEGRITY DM_VERITY; do
    grep -Fxq "CONFIG_$symbol=m" "$config" || {
        printf 'Missing optional storage module: %s\n' "$symbol" >&2; exit 1;
    }
done
printf 'Four filesystems, CPU AES, inline encryption and optional integrity prerequisites: passed\n'
