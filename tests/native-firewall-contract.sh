#!/usr/bin/env bash
# Check the original firewalld nftables backend's IPv4/IPv6 kernel primitives.
set -Eeuo pipefail
root=$(cd -- "$(dirname -- "$0")/.." && pwd)
config=${1:-$root/packaging/native/native.config}
grep -Fxq CONFIG_NF_TABLES_INET=y "$config"
for symbol in NF_TABLES NF_CONNTRACK NF_NAT NF_LOG_SYSLOG NF_CT_NETLINK \
    NETFILTER_NETLINK_LOG NFT_CT NFT_LOG NFT_LIMIT NFT_MASQ NFT_REDIR NFT_NAT \
    NFT_REJECT NFT_FIB_IPV4 NFT_FIB_IPV6 NFT_FIB_INET NFT_COMPAT; do
    grep -Fxq "CONFIG_$symbol=m" "$config" || { echo "Missing firewall module: $symbol" >&2; exit 1; }
done
if [[ $# == 2 ]]; then
    for module in nf_tables nf_conntrack nf_nat nf_log_syslog nf_conntrack_netlink \
        nfnetlink_log nft_ct nft_log nft_limit nft_masq nft_redir nft_nat \
        nft_reject nft_reject_ipv4 nft_reject_ipv6 nft_reject_inet \
        nft_fib_ipv4 nft_fib_ipv6 nft_fib_inet nft_compat; do
        [[ -n $(find "$2/net" -name "$module.ko" -type f -print -quit) ]] || {
            echo "Missing built firewall module: $module" >&2; exit 1;
        }
    done
fi
echo 'Native nftables, connection tracking, NAT, rejection, logging and IPv4/IPv6 FIB requirements passed'
