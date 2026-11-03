#!/usr/bin/env bash
# Check the resolved release configuration, not only the input fragment.
set -Eeuo pipefail
config=${1:?Pass the resolved kernel configuration}
for symbol in MODULE_SIG MODULE_SIG_FORCE MODULE_SIG_ALL MODULE_SIG_SHA256 \
    MODULE_SIG_KEY_TYPE_RSA SYSTEM_TRUSTED_KEYRING SECURITY_DMESG_RESTRICT \
    SECURITY_LOCKDOWN_LSM SECURITY_LOCKDOWN_LSM_EARLY LOCK_DOWN_KERNEL_FORCE_INTEGRITY \
    SECURITY_YAMA SECURITY_SELINUX FORTIFY_SOURCE HARDENED_USERCOPY \
    RANDOMIZE_BASE STACKPROTECTOR_STRONG STRICT_KERNEL_RWX STRICT_MODULE_RWX; do
    grep -Fxq "CONFIG_${symbol}=y" "$config" || {
        printf 'Required release protection missing: %s\n' "$symbol" >&2; exit 1;
    }
done
grep -Fxq 'CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"' "$config"
grep -Fxq 'CONFIG_SYSTEM_TRUSTED_KEYS=""' "$config"
lsm=$(sed -n 's/^CONFIG_LSM="\([^"]*\)"$/\1/p' "$config")
for name in lockdown yama selinux; do
    case ,$lsm, in *,"$name",*) ;; *) printf 'Required LSM missing: %s\n' "$name" >&2; exit 1;; esac
done
echo 'Resolved kernel release protections passed'
