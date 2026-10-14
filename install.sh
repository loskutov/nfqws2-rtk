#!/bin/sh
# User supplies the kernel modules; runtime downloads never replace the kernel.
set -eu
BASE=/var/config/nfqws2
BACKUP=/var/config/nfqws2.previous
HOOK=/var/config/run_test.sh
WORK=/tmp/nfqws2-rtk-install.$$
STAGE=/var/config/.nfqws2-rtk-stage.$$
MODULES_DIR=${MODULES_DIR:-./modules}
SOURCE_DIR=${SOURCE_DIR:-}
PROJECT_REF=${PROJECT_REF:-master}
PROJECT_URL=${PROJECT_URL:-https://raw.githubusercontent.com/loskutov/nfqws2-rtk}
NFQWS2_VERSION=${NFQWS2_VERSION:-latest}
NFQWS2_KEENETIC_REF=${NFQWS2_KEENETIC_REF:-latest}
INSECURE=${INSECURE:-0}
if [ -z "$SOURCE_DIR" ] && [ -f ./src/service.sh ]; then SOURCE_DIR=.; fi
fail() { echo "nfqws2-rtk: $*" >&2; exit 1; }
# The firmware's CA file contains only an ISP-specific root.
if [ -z "${CURL_CA_BUNDLE:-}" ]; then
    if [ -n "$SOURCE_DIR" ] && [ -r "$SOURCE_DIR/cacert.pem" ]; then
        CURL_CA_BUNDLE="$SOURCE_DIR/cacert.pem"
    elif [ -r ./cacert.pem ]; then
        CURL_CA_BUNDLE=./cacert.pem
    else
        fail 'provide cacert.pem from this repository, or set CURL_CA_BUNDLE'
    fi
fi
export CURL_CA_BUNDLE
fetch() {
    if [ "$INSECURE" = 1 ]; then curl -fkL --retry 2 --connect-timeout 15 --max-time 180 "$1" -o "$2"
    else curl -fL --retry 2 --connect-timeout 15 --max-time 180 "$1" -o "$2"; fi
}
source_file() {
    if [ -n "$SOURCE_DIR" ]; then cp "$SOURCE_DIR/$1" "$2"
    else fetch "$PROJECT_URL/$PROJECT_REF/$1" "$2"; fi
}
[ "$(id -u)" = 0 ] || fail 'root required'
case "$(uname -m)" in
    aarch64) runtime_arch=linux-arm64;;
    mips|mipsel)
        # uname often says mips for either byte order. Inspect the native ELF.
        native_elf=$(hexdump -v -n 6 -e '1/1 "%02x"' /bin/busybox) || fail 'cannot inspect native ELF'
        case "$native_elf" in
            7f454c460101) runtime_arch=linux-mipsel;;
            7f454c460102) runtime_arch=linux-mips;;
            *) fail 'requires a 32-bit MIPS userspace';;
        esac;;
    *) fail 'supported architectures: AArch64 and 32-bit MIPS';;
esac
[ -r /proc/fc/ctrl/skbmark_fwdByPs ] || fail 'requires the investigated FleetConntrack FWDBYPS interface'
[ -n "$SOURCE_DIR$PROJECT_URL" ] || fail 'set SOURCE_DIR to the checkout, or PROJECT_URL to its raw GitHub base URL'
case "$PROJECT_REF" in ''|*[!a-zA-Z0-9._/-]*) fail 'invalid PROJECT_REF';; esac
for module in xt_NFQUEUE nfnetlink_queue; do
    [ -r "$MODULES_DIR/$module.ko" ] || fail "provide $MODULES_DIR/$module.ko for your exact firmware"
    case "$(modinfo -F vermagic "$MODULES_DIR/$module.ko")" in
        "$(uname -r) "*) :;;
        *) fail "$module vermagic kernel release mismatch";;
    esac
done
NFQUEUE_NUM=300
if [ -e "$BASE" ]; then
    [ -f "$BASE/.managed-rtl9607f-nfqws2" ] || fail 'existing installation is unmanaged'
    [ ! -e "$BACKUP" ] || fail 'archive the existing .previous backup before updating'
    [ ! -f "$BASE/settings" ] || . "$BASE/settings"
fi
case "$NFQUEUE_NUM" in ''|*[!0-9]*) fail 'invalid NFQUEUE_NUM';; esac
[ "$NFQUEUE_NUM" -le 65535 ] || fail 'NFQUEUE_NUM must be 0..65535'
if awk -v q="$NFQUEUE_NUM" '$1+0==q+0 {found=1;exit} END {exit !found}' /proc/net/netfilter/nfnetlink_queue 2>/dev/null; then
    fail "queue $NFQUEUE_NUM is occupied; stop its listener first"
fi
if [ -e "$HOOK" ]; then grep -q '^# RTL9607F-NFQWS2-BOOT-v1$' "$HOOK" || fail 'existing run_test.sh is unmanaged; merge explicitly'; fi
available=$(df -k /var/config | awk 'END {print $4}')
case "$available" in ''|*[!0-9]*) fail 'cannot determine free config space';; esac
[ "$available" -ge 2048 ] || fail 'need at least 2 MiB free config space'
umask 077
mkdir "$WORK"
cleanup() { rm -rf "$WORK" "$STAGE"; }
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
mkdir -p "$STAGE/lua" "$STAGE/blobs" "$STAGE/modules" "$STAGE/lists"
for file in service.sh kernel-id.sh module-load.sh settings https.args quic.args; do source_file "src/$file" "$STAGE/$file" || fail "cannot fetch $file"; done
sh "$STAGE/kernel-id.sh" > "$WORK/kernel.identity" || fail 'cannot establish running kernel identity'
if [ -f "$MODULES_DIR/kernel.identity" ]; then
    # Explicit approval supplied alongside revalidated/rebuilt modules.
    cmp -s "$MODULES_DIR/kernel.identity" "$WORK/kernel.identity" || fail 'supplied module approval does not match the running kernel'
    cp "$MODULES_DIR/kernel.identity" "$STAGE/kernel.identity"
elif [ -d "$BASE" ]; then
    [ -f "$BASE/kernel.identity" ] || fail 'approved kernel identity missing'
    cmp -s "$BASE/kernel.identity" "$WORK/kernel.identity" || fail 'kernel changed; revalidate modules and provide modules/kernel.identity'
    cp "$BASE/kernel.identity" "$STAGE/kernel.identity"
else
    cp "$WORK/kernel.identity" "$STAGE/kernel.identity"
fi
source_file LICENSE "$STAGE/LICENSE-nfqws2-rtk" || fail 'cannot fetch license'
for module in xt_NFQUEUE nfnetlink_queue; do cp "$MODULES_DIR/$module.ko" "$STAGE/modules/"; done
if [ "$NFQWS2_VERSION" = latest ]; then
    fetch https://api.github.com/repos/bol-van/zapret2/releases/latest "$WORK/release.json" || fail 'latest release lookup failed'
    NFQWS2_VERSION=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORK/release.json" | head -n 1)
fi
case "$NFQWS2_VERSION" in v[0-9]*) :;; *) fail 'invalid upstream release tag';; esac
case "$NFQWS2_VERSION" in *[!a-zA-Z0-9._-]*) fail 'unsafe upstream release tag';; esac
prefix="zapret2-$NFQWS2_VERSION"
release="https://github.com/bol-van/zapret2/releases/download/$NFQWS2_VERSION"
fetch "$release/$prefix.tar.gz" "$WORK/runtime.tar.gz" || fail 'runtime download failed'
fetch "$release/sha256sum.txt" "$WORK/upstream.sha256" || fail 'checksum manifest download failed'
# Extract only explicitly named members. No arbitrary archive paths are unpacked.
tar -xOzf "$WORK/runtime.tar.gz" "$prefix/binaries/$runtime_arch/nfqws2" > "$STAGE/nfqws2" || fail "$runtime_arch runtime absent"
for file in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
    tar -xOzf "$WORK/runtime.tar.gz" "$prefix/lua/$file" > "$STAGE/lua/$file" || fail "runtime missing $file"
done
tar -xOzf "$WORK/runtime.tar.gz" "$prefix/docs/LICENSE.txt" > "$STAGE/LICENSE-zapret2" || fail 'upstream license missing'
expected=$(awk -v p="$prefix/binaries/$runtime_arch/nfqws2" '$2==p {print $1}' "$WORK/upstream.sha256")
[ "${#expected}" = 64 ] || fail 'runtime absent from upstream checksum manifest'
if which sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$STAGE/nfqws2"); [ "${actual%% *}" = "$expected" ] || fail 'upstream binary checksum mismatch'
else
    # This ONT has md5sum but no SHA256 tool. TLS remains required by default.
    echo 'No sha256sum: upstream SHA256 recorded; download relies on HTTPS. Verify offline if using INSECURE=1.' >&2
    [ "$INSECURE" != 1 ] || fail 'INSECURE=1 requires sha256sum for runtime verification'
fi
if [ "$NFQWS2_KEENETIC_REF" = latest ]; then
    fetch https://api.github.com/repos/nfqws/nfqws2-keenetic/releases/latest "$WORK/nfqws2-keenetic-release.json" || fail 'latest nfqws2-keenetic release lookup failed'
    NFQWS2_KEENETIC_REF=$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WORK/nfqws2-keenetic-release.json" | head -n 1)
fi
case "$NFQWS2_KEENETIC_REF" in ''|*[!a-zA-Z0-9._-]*) fail 'invalid nfqws2-keenetic release tag';; esac
printf '%s\n' "$NFQWS2_KEENETIC_REF" > "$STAGE/NFQWS2-KEENETIC-REF"
nfqws2_keenetic="https://raw.githubusercontent.com/nfqws/nfqws2-keenetic/$NFQWS2_KEENETIC_REF/etc/nfqws2"
for file in tls_clienthello.bin quic_initial.bin; do fetch "$nfqws2_keenetic/blobs/$file" "$STAGE/blobs/$file" || fail "cannot fetch $file"; done
for file in user.list exclude.list; do fetch "$nfqws2_keenetic/lists/$file" "$STAGE/lists/$file" || fail "cannot fetch $file"; done
: > "$STAGE/lists/auto.list"
printf '%s\n' "$NFQWS2_VERSION" > "$STAGE/VERSION"
printf '%s\n' "$expected" > "$STAGE/UPSTREAM-SHA256"
echo 1 > "$STAGE/.managed-rtl9607f-nfqws2"
# Candidate files are staged, but no installation or boot-hook change precedes
# this load check. A panic here cannot enable the candidate on the next boot.
sh "$STAGE/module-load.sh" "$STAGE/modules" "$STAGE/kernel.identity" || fail 'module preflight failed; persistent installation unchanged'
had_old=0
if [ -d "$BASE" ]; then
    sh "$BASE/service.sh" stop || fail 'cannot stop old service'
    cp "$BASE/settings" "$STAGE/settings"
    for file in https.args quic.args; do [ ! -f "$BASE/$file" ] || cp "$BASE/$file" "$STAGE/$file"; done
    cp "$BASE/lists/"*.list "$STAGE/lists/"
fi
(cd "$STAGE" && md5sum nfqws2 service.sh kernel-id.sh module-load.sh kernel.identity VERSION UPSTREAM-SHA256 LICENSE-* lua/* blobs/* modules/* > MD5SUMS)
chmod 755 "$STAGE" "$STAGE/lua" "$STAGE/blobs" "$STAGE/modules"
chmod 755 "$STAGE/nfqws2" "$STAGE/service.sh"
chmod 644 "$STAGE/lua/"* "$STAGE/blobs/"*
chmod 700 "$STAGE/lists"
if [ -d "$BASE" ]; then mv "$BASE" "$BACKUP"; had_old=1; fi
mv "$STAGE" "$BASE"
new_hook=0
if [ ! -e "$HOOK" ]; then
    cat > "$HOOK" <<'BOOT'
#!/bin/sh
# RTL9607F-NFQWS2-BOOT-v1
exec sh /var/config/nfqws2/service.sh start
BOOT
    chmod 700 "$HOOK"; new_hook=1
fi
if ! sh "$BASE/service.sh" start; then
    sh "$BASE/service.sh" stop || fail 'cannot stop new supervisor; files retained for inspection'
    rm -rf "$BASE"
    [ "$had_old" = 0 ] || mv "$BACKUP" "$BASE"
    [ "$new_hook" = 0 ] || rm -f "$HOOK"
    fail 'startup failed; previous files restored if present (service stopped). Inspect /tmp/nfqws2 logs'
fi
echo "Installed nfqws2-rtk with upstream nfqws2 $NFQWS2_VERSION"
echo 'Control: sh /var/config/nfqws2/service.sh start|stop|restart|status|save'
