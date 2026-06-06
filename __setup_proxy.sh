#!/bin/bash
set -e

SHOW_LOGS="$(echo "${SHOW_LOGS:-false}" | tr '[:upper:]' '[:lower:]')"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

func_net_admin() {
    if ! iptables -L >/dev/null 2>&1; then
        log "[ERROR] Cannot use iptables — missing required permissions."
        log "[INFO] Fix: add --cap-add=NET_ADMIN --cap-add=NET_RAW --sysctl net.ipv4.ip_forward=1 to your docker run command"
        exit 1
    fi
}

func_start_warp() {
    log "[INFO] Starting Cloudflare WARP in proxy mode..."

    log "[STOP] Clearing old WARP data..."
    rm -rf /var/lib/cloudflare-warp/* 2>/dev/null || true
    sleep 2

    log "[START] Starting message bus (dbus)..."
    mkdir -p /run/dbus
    dbus-daemon --system --fork >/dev/null 2>&1 &
    sleep 2

    log "[START] Starting WARP service..."
    warp-svc >/dev/null 2>&1 &
    sleep 2

    log "[WARP] Registering your device with Cloudflare..."
    warp-cli --accept-tos registration new || true
    sleep 2

    log "[WARP] Connecting (first attempt)..."
    echo y | warp-cli --accept-tos connect || true
    sleep 2

    log "[WARP] Connecting (second attempt)..."
    warp-cli --accept-tos connect || true
    sleep 2

    log "[WARP] Setting mode to proxy..."
    warp-cli --accept-tos mode proxy || true
    sleep 2

    log "[WARP] Setting proxy port to 40000..."
    warp-cli --accept-tos proxy port "40000" || true
    sleep 2

    log "[WARP] Checking connection status..."
    warp-cli --accept-tos status || true
    sleep 5

    log "[CHECK] Verifying WARP is listening on port 40000..."
    netstat -lntup | grep 40000
    log "[CHECK] Testing WARP proxy through Cloudflare..."
    curl -s --socks5 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep warp
}

func_check_warp() {
    while true; do
        sleep 10
        resp=$(curl -L --max-redirs 10 --socks5 127.0.0.1:40000 -s --max-time 30 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null | tr -d '\n\r' || true)
        if echo "$resp" | grep -qi "warp=on"; then
            log "[OK] WARP proxy is working! Traffic is going through Cloudflare."
            return 0
        else
            log "[WAIT] WARP proxy not ready yet, checking again in 10 seconds..."
        fi
    done
}

setup_redsocks() {
    cat > /etc/redsocks.conf <<EOF
base {
    log_debug = off;
    log_info = on;
    log = "stderr";
    daemon = off;
    redirector = iptables;
}
redsocks {
    local_ip = 127.0.0.1;
    local_port = 50000;
    ip = 127.0.0.1;
    port = 40000;
    type = socks5;
}
EOF
    if [ "$SHOW_LOGS" = "true" ]; then
        cat /etc/redsocks.conf
    fi
    log "[OK] Redsocks configuration saved to /etc/redsocks.conf"
}

setup_iptables() {
    iptables -t nat -F
    iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 50000 -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 40000 -j RETURN
    iptables -t nat -A OUTPUT -p udp -d 127.0.0.1 -j RETURN
    iptables -t nat -A OUTPUT -p udp --dport 53 -j RETURN
    iptables -t nat -A OUTPUT -p udp --dport 50000 -j RETURN
    iptables -t nat -A OUTPUT -p udp --dport 40000 -j RETURN
    iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-ports 50000
    log "[OK] iptables rules applied — all outbound traffic will go through WARP"
}

func_expose_warp() {
    log "[EXPOSE] Opening WARP SOCKS5 on 0.0.0.0:40001 for external access..."
    socat TCP-LISTEN:40001,fork,reuseaddr TCP:127.0.0.1:40000 &
    log "[OK] WARP SOCKS5 now available at 0.0.0.0:40001"
}

func_set_proxy() {
    log "[START] Setting up full proxy stack (WARP + Redsocks + iptables)..."

    pkill -f warp-svc || true
    pkill -f warp-cli || true
    sleep 2

    func_start_warp
    func_check_warp
    func_expose_warp
    setup_redsocks
    setup_iptables

    if [ "$SHOW_LOGS" = "true" ]; then
        redsocks -c /etc/redsocks.conf &
    else
        redsocks -c /etc/redsocks.conf >/dev/null 2>&1 &
    fi
    redsocks_pid=$!
    sleep 10

    checker=$(printf "%s\n" $CHECKERS | shuf -n1)
    resp=$(curl -L --max-redirs 10 -s --max-time 30 "https://${checker}" || true)
    if [ -n "$resp" ]; then
        log "[OK] Global proxy is working! Your IP: $resp (checked via $checker)"
        touch /tmp/redsocks.ready
        return 0
    else
        log "[FAIL] Global proxy test failed — no internet through the proxy"
        return 1
    fi
}

func_global_monitor() {
    while true; do
        log "[RESTART] Shutting down old WARP and Redsocks processes..."
        pkill -f warp-svc || true
        pkill -f warp-cli || true
        pkill -f redsocks || true
        pkill -f socat || true
        rm -f /tmp/redsocks.ready || true

        func_set_proxy || { sleep 60; continue; }

        proxy_fail_count=0
        while true; do
            sleep 180
            checker=$(printf "%s\n" $CHECKERS | shuf -n1)
            resp=$(curl -L --max-redirs 10 -s --max-time 30 "https://${checker}" 2>/dev/null | tr -d '\n\r' || true)
            if [ -n "$resp" ]; then
                log "[OK] Internet check passed — your IP: $resp (via $checker)"
                proxy_fail_count=0
            else
                proxy_fail_count=$((proxy_fail_count+1))
                log "[WARN] Internet check failed (${proxy_fail_count}/3 failures)"
            fi
            if [ ${proxy_fail_count} -ge 3 ]; then
                log "[RESTART] 3 internet checks failed — restarting the whole proxy stack..."
                break
            fi
        done
    done
}

CHECKERS="ifconfig.icu/ip
ifconfig.me/ip
ipecho.net/ip
ipinfo.io/ip
ipapi.co/ip
ip.im
eth0.me
ip.tyk.nu
a.ident.me
ip-addr.es
icanhazip.com
api64.ipify.org
wtfismyip.com/text
moanmyip.com/simple
checkip.amazonaws.com
whatismyip.akamai.com
jsonip.com
httpbin.org/ip"

func_net_admin
func_global_monitor
