#!/bin/sh
# SP-GE3001 only. No vendor daemon, watchdog, or global acceleration changes.
set -u
BASE=/var/config/nfqws2
RUN=/tmp/nfqws2
LOCK=/tmp/nfqws2-control.lock
PRE=nfqws_pre
POST=nfqws_post
NFQUEUE_NUM=300
ISP_INTERFACE=ppp0
WINDOW=20
UDP_WINDOW=15
TCP_PORTS=443
UDP_PORTS=443
SAVE_INTERVAL=600
MAX_LIST_BYTES=262144
DEBUG=0
[ ! -f "$BASE/settings" ] || . "$BASE/settings"

die() { echo "nfqws2: $*" >&2; exit 1; }
ipt() { iptables -t mangle "$@"; }
root_check() { [ "$(id -u)" = 0 ] || die 'root required'; }
pid_matches() {
    [ -r "$1" ] || return 1
    read -r p < "$1"
    case "$p" in ''|*[!0-9]*) return 1;; esac
    [ "$p" -gt 1 ] && kill -0 "$p" 2>/dev/null || return 1
    tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -F "$2" >/dev/null
}
queue_bound() {
    grep -q "^[[:space:]]*$NFQUEUE_NUM[[:space:]]" /proc/net/netfilter/nfnetlink_queue 2>/dev/null
}
validate_settings() {
    case "$NFQUEUE_NUM" in ''|*[!0-9]*) die 'NFQUEUE_NUM must be 0..65535';; esac
    [ "$NFQUEUE_NUM" -ge 0 ] && [ "$NFQUEUE_NUM" -le 65535 ] || die 'NFQUEUE_NUM must be 0..65535'
    [ -n "$ISP_INTERFACE" ] || die 'ISP_INTERFACE is empty'
    for interface in $ISP_INTERFACE; do
        case "$interface" in *[!a-zA-Z0-9_.:-]*) die 'invalid interface name';; esac
    done
    case "$WINDOW:$SAVE_INTERVAL:$MAX_LIST_BYTES:$DEBUG" in *[!0-9:]*) die 'invalid numeric setting';; esac
    [ "$WINDOW" -ge 5 ] && [ "$WINDOW" -le 100 ] || die 'WINDOW must be 5..100'
    case "$UDP_WINDOW" in ''|*[!0-9]*) die 'invalid UDP_WINDOW';; esac
    [ "$UDP_WINDOW" -ge 1 ] && [ "$UDP_WINDOW" -le 100 ] || die 'UDP_WINDOW must be 1..100'
    for ports in "$TCP_PORTS" "$UDP_PORTS"; do
        case "$ports" in *[!0-9,]*) die 'port lists must contain comma-separated numeric ports';; esac
        for port in $(printf '%s' "$ports" | tr ',' ' '); do
            [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || die 'invalid port'
        done
    done
    [ -n "$TCP_PORTS$UDP_PORTS" ] || die 'at least one protocol must be enabled'
    [ "$SAVE_INTERVAL" -ge 60 ] || die 'SAVE_INTERVAL must be at least 60'
}
kernel_check() {
    [ -r "$BASE/kernel.identity" ] || die 'approved kernel identity missing; modules will not be loaded'
    current=$(sh "$BASE/kernel-id.sh") || die 'cannot verify running kernel; modules will not be loaded'
    approved=$(cat "$BASE/kernel.identity") || die 'cannot read approved kernel identity'
    [ "$current" = "$approved" ] || die 'kernel changed; revalidate modules before starting (nothing loaded)'
}
check() {
    kernel_check
    case "$(uname -m)" in
        aarch64|mips|mipsel) :;;
        *) die 'this package requires AArch64 or 32-bit MIPS';;
    esac
    for module in xt_NFQUEUE nfnetlink_queue; do
        case "$(modinfo -F vermagic "$BASE/modules/$module.ko")" in
            "$(uname -r) "*) :;;
            *) die "$module kernel release does not match; supply compatible modules";;
        esac
    done
    [ -r /proc/fc/ctrl/skbmark_fwdByPs ] || die 'FleetConntrack interface absent'
    grep -q '^MARK2$' /proc/net/ip_tables_targets || die 'MARK2 target absent'
    grep -q '^connbytes$' /proc/net/ip_tables_matches || die 'connbytes match absent'
    grep -q '^conntrack$' /proc/net/ip_tables_matches || die 'conntrack match absent'
    validate_settings
    (cd "$BASE" && md5sum -c MD5SUMS) || die 'runtime checksum mismatch'
}
ensure() { chain=$1; shift; ipt -C "$chain" "$@" 2>/dev/null || ipt -A "$chain" "$@"; }
jump() { ipt -C "$1" -j "$2" 2>/dev/null || ipt -I "$1" 1 -j "$2"; }
protocol_firewall() {
    proto=$1; ports=$2; window=$3
    for interface in $ISP_INTERFACE; do
    for port in $(printf '%s' "$ports" | tr ',' ' '); do
        # Interface selection follows nfqws2-keenetic.
        # Set FWDBYPS before queueing and before the vendor's egress learner.
        set -- -o "$interface" -p "$proto" --dport "$port"
        ensure "$POST" "$@" \
            -m connbytes --connbytes "1:$window" --connbytes-dir original --connbytes-mode packets \
            -j MARK2 --or-mark2 0x1 || return 1
        ensure "$POST" "$@" \
            -m connbytes --connbytes "1:$window" --connbytes-dir original --connbytes-mode packets \
            -m mark ! --mark 0x40000000/0x40000000 \
            -j NFQUEUE --queue-num "$NFQUEUE_NUM" --queue-bypass || return 1
        set -- -i "$interface" -p "$proto" --sport "$port" -m conntrack --ctdir REPLY
        ensure "$PRE" "$@" \
            -m connbytes --connbytes "1:$window" --connbytes-dir reply --connbytes-mode packets \
            -j MARK2 --or-mark2 0x1 || return 1
        ensure "$PRE" "$@" \
            -m connbytes --connbytes "1:$window" --connbytes-dir reply --connbytes-mode packets \
            -m mark ! --mark 0x40000000/0x40000000 \
            -j NFQUEUE --queue-num "$NFQUEUE_NUM" --queue-bypass || return 1
    done
    done
    return 0
}
firewall() {
    ipt -nL "$PRE" >/dev/null 2>&1 || ipt -N "$PRE" || return 1
    ipt -nL "$POST" >/dev/null 2>&1 || ipt -N "$POST" || return 1
    protocol_firewall tcp "$TCP_PORTS" "$WINDOW" || return 1
    protocol_firewall udp "$UDP_PORTS" "$UDP_WINDOW" || return 1
    jump PREROUTING "$PRE" && jump POSTROUTING "$POST"
}
unhook() {
    while ipt -C PREROUTING -j "$PRE" 2>/dev/null; do ipt -D PREROUTING -j "$PRE" || break; done
    while ipt -C POSTROUTING -j "$POST" 2>/dev/null; do ipt -D POSTROUTING -j "$POST" || break; done
    ipt -F "$PRE" 2>/dev/null || :
    ipt -F "$POST" 2>/dev/null || :
    ipt -X "$PRE" 2>/dev/null || :
    ipt -X "$POST" 2>/dev/null || :
}
save_list() {
    f="$RUN/lists/auto.list"
    [ -f "$f" ] || return 0
    n=$(wc -c < "$f")
    if [ "$n" -gt "$MAX_LIST_BYTES" ]; then echo 'auto.list too large; persistent save skipped' >&2; return 1; fi
    cmp -s "$f" "$BASE/lists/auto.list" && return 0
    # Snapshot first; reject a copy that grew beyond the bound during copying.
    tmp="$BASE/lists/.auto.list.$$"
    cp "$f" "$tmp" || return 1
    n=$(wc -c < "$tmp")
    if [ "$n" -gt "$MAX_LIST_BYTES" ]; then rm -f "$tmp"; return 1; fi
    chmod 600 "$tmp"
    mv -f "$tmp" "$BASE/lists/auto.list"
}
profile_lists() {
    cat >> "$RUN/args" <<EOF
--hostlist=$RUN/lists/user.list
--hostlist-auto=$RUN/lists/auto.list
--hostlist-exclude=$RUN/lists/exclude.list
EOF
}
make_config() {
    cat > "$RUN/args" <<EOF
--qnum=$NFQUEUE_NUM
--uid=65534
--fwmark=0x40000000
--debug=$DEBUG
--lua-init=@$BASE/lua/zapret-lib.lua
--lua-init=@$BASE/lua/zapret-antidpi.lua
--lua-init=@$BASE/lua/zapret-auto.lua
--hostlist-auto-fail-threshold=3
--hostlist-auto-fail-time=60
--hostlist-auto-retrans-threshold=3
--hostlist-auto-retrans-reset=0
--hostlist-auto-debug=$RUN/learn.log
EOF
    set -- $ISP_INTERFACE
    [ "$#" -le 1 ] || echo --bind-fix4 >> "$RUN/args"
    separator=
    if [ -n "$TCP_PORTS" ]; then
        printf '%s\n' --filter-l3=ipv4 "--filter-tcp=$TCP_PORTS" --filter-l7=tls "--out-range=-n$WINDOW" >> "$RUN/args"
        profile_lists
        sed '/^[[:space:]]*#/d' "$BASE/https.args" >> "$RUN/args"
        separator=--new
    fi
    if [ -n "$UDP_PORTS" ]; then
        [ -z "$separator" ] || echo "$separator" >> "$RUN/args"
        printf '%s\n' --filter-l3=ipv4 "--filter-udp=$UDP_PORTS" --filter-l7=quic "--out-range=-n$UDP_WINDOW" >> "$RUN/args"
        profile_lists
        sed '/^[[:space:]]*#/d' "$BASE/quic.args" >> "$RUN/args"
    fi
}
prepare() {
    mkdir -p "$RUN/lists" || die 'cannot create runtime directory'
    chmod 755 "$RUN"
    cp "$BASE/lists/user.list" "$BASE/lists/exclude.list" "$RUN/lists/" || die 'copy lists failed'
    cp "$BASE/lists/auto.list" "$RUN/lists/auto.list" || die 'copy auto list failed'
    touch "$RUN/learn.log"
    chown -R 65534:65534 "$RUN/lists" "$RUN/learn.log" || die 'chown failed'
    chmod 700 "$RUN/lists"
    make_config
    # Validate file paths, option parsing, and access under the intended UID without NFQUEUE.
    echo --dry-run > "$RUN/check.args"
    cat "$RUN/args" >> "$RUN/check.args"
    "$BASE/nfqws2" "@$RUN/check.args" > "$RUN/check.log" 2>&1 || die "configuration rejected; see $RUN/check.log"
    kernel_check || return 1
    for m in xt_NFQUEUE nfnetlink_queue; do
        grep -q "^$m " /proc/modules || insmod "$BASE/modules/$m.ko" || die "cannot load $m"
    done
    echo 1 > /proc/sys/net/netfilter/nf_conntrack_acct || die 'cannot enable accounting'
}
rotate_logs() {
    for f in "$RUN/daemon.log" "$RUN/learn.log"; do
        [ ! -f "$f" ] || [ "$(wc -c < "$f")" -lt 524288 ] || {
            cp "$f" "$f.previous" && : > "$f"
        }
    done
}
supervise() {
    trap '' HUP
    echo $$ > "$RUN/supervisor.pid"
    child=
    finish() {
        trap '' TERM INT
        unhook
        if [ -n "$child" ]; then
            kill "$child" 2>/dev/null || :
            wait "$child" 2>/dev/null || :
        fi
        save_list || :
        rm -f "$RUN/supervisor.pid" "$RUN/daemon.pid"
        exit 0
    }
    trap finish TERM INT
    failures=0
    while [ "$failures" -lt 3 ]; do
        rotate_logs
        "$BASE/nfqws2" "@$RUN/args" >> "$RUN/daemon.log" 2>&1 &
        child=$!
        echo "$child" > "$RUN/daemon.pid"
        ready=0
        for i in 1 2 3 4 5 6 7 8 9 10; do
            if queue_bound; then ready=1; break; fi
            kill -0 "$child" 2>/dev/null || break
            sleep 1
        done
        if [ "$ready" = 1 ]; then
            if ! firewall; then echo 'firewall setup failed' >&2; finish; fi
            echo ready > "$RUN/ready"
            elapsed=0
            ticks=0
            while kill -0 "$child" 2>/dev/null; do
                sleep 5
                ticks=$((ticks+1)); elapsed=$((elapsed+5))
                if [ "$ticks" -ge 6 ]; then
                    ticks=0
                    [ "$(cat /proc/sys/net/netfilter/nf_conntrack_acct)" = 1 ] || echo 1 > /proc/sys/net/netfilter/nf_conntrack_acct
                    firewall || { echo 'firewall repair failed' >&2; finish; }
                    rotate_logs
                fi
                if [ "$elapsed" -ge "$SAVE_INTERVAL" ]; then save_list || :; elapsed=0; fi
            done
        fi
        unhook
        rm -f "$RUN/ready"
        kill "$child" 2>/dev/null || :
        wait "$child" 2>/dev/null || :
        child=
        failures=$((failures+1))
        echo "nfqws2 exited; restart attempt $failures/3 after 30 seconds" >&2
        sleep 30
    done
    echo 'Restart limit reached; bypass stopped. See daemon.log.' >&2
    finish
}
start() {
    validate_settings
    if pid_matches "$RUN/supervisor.pid" "$BASE/service.sh supervise"; then echo 'Already running'; return 0; fi
    queue_bound && die "queue $NFQUEUE_NUM is already owned; stop its listener first"
    check
    prepare
    rm -f "$RUN/ready"
    (trap '' HUP; exec sh "$BASE/service.sh" supervise) </dev/null >> "$RUN/service.log" 2>&1 &
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if [ -f "$RUN/ready" ]; then echo "Started: interfaces=$ISP_INTERFACE IPv4 TCP=$TCP_PORTS UDP=$UDP_PORTS queue=$NFQUEUE_NUM"; return 0; fi
        sleep 1
    done
    die "startup not ready; inspect $RUN/service.log and daemon.log"
}
stop() {
    if pid_matches "$RUN/supervisor.pid" "$BASE/service.sh supervise"; then
        kill "$p"
        for i in 1 2 3 4 5 6 7 8 9 10; do
            pid_matches "$RUN/supervisor.pid" "$BASE/service.sh supervise" || break
            sleep 1
        done
        pid_matches "$RUN/supervisor.pid" "$BASE/service.sh supervise" && die 'supervisor has not stopped; inspect before retrying'
    else
        unhook
        if pid_matches "$RUN/daemon.pid" "$BASE/nfqws2"; then kill "$p"; fi
        save_list || :
    fi
    rm -f "$RUN/ready"
    echo 'Stopped; modules remain loaded; accounting remains enabled'
}
case "${1:-status}" in
    supervise) root_check; validate_settings; supervise;;
    status)
        if pid_matches "$RUN/supervisor.pid" "$BASE/service.sh supervise"; then echo "Supervisor PID=$p"; else echo 'Supervisor stopped'; fi
        if pid_matches "$RUN/daemon.pid" "$BASE/nfqws2"; then echo "nfqws2 PID=$p"; else echo 'nfqws2 stopped'; fi
        ipt -nvL "$PRE" 2>/dev/null || :; ipt -nvL "$POST" 2>/dev/null || :;;
    start|stop|restart|save|check)
        root_check
        mkdir "$LOCK" 2>/dev/null || die "control lock exists: $LOCK (another operation may be running)"
        trap 'rm -r "$LOCK"' EXIT
        case "$1" in start) start;; stop) stop;; restart) stop; start;; save) save_list;; check) check;; esac;;
    *) die 'Usage: service.sh start|stop|restart|status|save|check';;
esac
