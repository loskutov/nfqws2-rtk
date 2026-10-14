#!/bin/sh
# Fingerprint the running kernel, never an on-flash slot awaiting reboot.
# MD5 detects accidental firmware changes; this is not an adversarial trust check.
set -eu
fail() { echo "nfqws2 kernel identity: $*" >&2; exit 1; }
notes=/sys/kernel/notes
version=/proc/version
config=/proc/config.gz
[ -r "$notes" ] || fail 'running kernel notes unavailable; refusing a weak version-only identity'
# Require an ELF GNU build-ID note (type 3), in either byte order.
hex=$(hexdump -v -e '1/1 "%02x"' "$notes") || fail 'cannot read kernel notes'
printf '%s\n' "$hex" | grep -Eq '04000000[0-9a-f]{8}03000000474e5500|00000004[0-9a-f]{8}00000003474e5500' || fail 'GNU kernel build ID unavailable'
[ -r "$version" ] || fail 'running kernel version unavailable'
[ -r "$config" ] || fail 'running kernel configuration unavailable'
printf '%s\n' 'nfqws2-kernel-identity-v1'
for file in "$notes" "$version" "$config"; do
    sum=$(md5sum "$file") || fail "cannot fingerprint $file"
    printf '%s\n' "${sum%% *}"
done
