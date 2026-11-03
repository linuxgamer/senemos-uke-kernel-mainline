#!/usr/bin/env bash
set -Eeuo pipefail
# A future RC needs its own reviewed source queue and signed upstream archive.
[[ $# == 1 && $1 =~ ^7[.]4-rc[1-9][0-9]*$ ]] || {
 printf '%s\n' 'The unstable channel is reserved for reviewed Linux 7.4-rcN sources; no build was started.' >&2
 exit 1
}
