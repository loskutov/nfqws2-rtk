#!/bin/sh
# Never unload modules automatically. Receipts describe loads performed this boot.
set -eu
modules=$1
identity=$2
state=/tmp/nfqws2-module-loads
fail() { echo "nfqws2 module preflight: $*" >&2; exit 1; }
receipt() {
    sum=$(md5sum "$modules/$1.ko") || return 1
    printf '%s\n' "${sum%% *}"
    cat "$identity" || return 1
    # Reference counts change when rules/listeners are installed; keep identity
    # fields only (name, allocation size, load address).
    awk -v name="$1" '$1==name {print $1, $2, $6; found=1} END {exit !found}' /proc/modules || return 1
}
# Check every already-loaded candidate before attempting any new load.
for module in xt_NFQUEUE nfnetlink_queue; do
    if grep -q "^$module " /proc/modules; then
        [ -r "$state/$module" ] || fail "$module is already loaded without a receipt; reboot before installing"
        current=$(receipt "$module") || fail "cannot identify $module"
        recorded=$(cat "$state/$module") || fail "cannot read $module receipt"
        [ "$current" = "$recorded" ] || fail "$module candidate differs from the recorded load; reboot before installing"
    fi
done
mkdir -p "$state"
chmod 700 "$state"
for module in xt_NFQUEUE nfnetlink_queue; do
    if ! grep -q "^$module " /proc/modules; then
        echo "Test-loading $module before enabling persistent startup"
        insmod "$modules/$module.ko" || fail "cannot load $module; persistent installation unchanged"
        receipt "$module" > "$state/$module.new" || fail "cannot record $module load"
        mv "$state/$module.new" "$state/$module"
    fi
done
