#!/bin/bash
set -e

WARP_PORT="${WARP_PORT:-40000}"
REDSOCKS_PORT="${REDSOCKS_PORT:-50000}"
WARP_MODE="${WARP_MODE:-proxy}"
SHOW_LOGS="$(echo "${SHOW_LOGS:-false}" | tr '[:upper:]' '[:lower:]')"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

func_net_admin() {
    if ! iptables -L >/dev/null 2>&1; then
        log "[ERROR] iptables not usable. Missing NET_ADMIN/NET_RAW or root privileges."
        log "[INFO] Run container with: --cap-add=NET_ADMIN --cap-add=NET_RAW --sysctl net.ipv4.ip_forward=1"
        exit 1
    fi
}

func_start_warp() {
    log "[INFO] Starting Cloudflare WARP in ${WARP_MODE} mode..."

	log "[CMD] rm -rf /var/lib/cloudflare-warp/* 2>/dev/null || true"
    rm -rf /var/lib/cloudflare-warp/* 2>/dev/null || true
    sleep 2

    mkdir -p /run/dbus
	log "[CMD] dbus-daemon --system --fork >/dev/null 2>&1 &"
    dbus-daemon --system --fork >/dev/null 2>&1 &
    sleep 2

	log "[CMD] warp-svc >/dev/null 2>&1 &"
    warp-svc >/dev/null 2>&1 &
    sleep 2

	log "[CMD] warp-cli --accept-tos registration new"
    warp-cli --accept-tos registration new
    sleep 2

	log "[CMD] echo y | warp-cli --accept-tos connect"
	echo y | warp-cli --accept-tos connect
	sleep 2
	
	log "[CMD] warp-cli --accept-tos connect"
	warp-cli --accept-tos connect
	sleep 2

	log "[CMD] warp-cli --accept-tos mode ${WARP_MODE}"
    warp-cli --accept-tos mode ${WARP_MODE}
	sleep 2
	
	log "[CMD] warp-cli --accept-tos proxy port ${WARP_PORT}"
    warp-cli --accept-tos proxy port "${WARP_PORT}"
    sleep 2

	log "[CMD] warp-cli --accept-tos status"
    warp-cli --accept-tos status
	sleep 5
	
	log "[CMD] netstat -lntup | grep 40000"
	netstat -lntup | grep 40000
	log "[CMD] curl -s --socks5 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep warp"
	curl -s --socks5 127.0.0.1:40000 https://www.cloudflare.com/cdn-cgi/trace | grep warp
}

func_check_warp() {
    while true; do
        sleep 10
        checker=$(printf "%s\n" $CHECKERS | shuf -n1)
        resp=$(curl -L --max-redirs 10 --socks5 127.0.0.1:${WARP_PORT} -s --max-time 30 "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null | tr -d '\n\r' || true)
        if echo "$resp" | grep -qi "warp=on"; then
            log "[INFO] WARP proxy is working: $resp"
            return 0
        else
            log "[WARN] WARP proxy not ready, retrying..."
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
    local_port = ${REDSOCKS_PORT};
    ip = 127.0.0.1;
    port = ${WARP_PORT};
    type = socks5;
}
EOF
    if [ "$SHOW_LOGS" = "true" ]; then
        cat /etc/redsocks.conf
    fi
    log "[INFO] Redsocks config written"
}

setup_iptables() {
    iptables -t nat -F
    iptables -t nat -A OUTPUT -p tcp -d 127.0.0.1 -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport ${REDSOCKS_PORT} -j RETURN
    iptables -t nat -A OUTPUT -p tcp --dport ${WARP_PORT} -j RETURN
    iptables -t nat -A OUTPUT -p udp -d 127.0.0.1 -j RETURN
    iptables -t nat -A OUTPUT -p udp --dport 53 -j RETURN
    iptables -t nat -A OUTPUT -p udp --dport ${REDSOCKS_PORT} -j RETURN
    iptables -t nat -A OUTPUT -p udp --dport ${WARP_PORT} -j RETURN
    iptables -t nat -A OUTPUT -p tcp -j REDIRECT --to-ports ${REDSOCKS_PORT}
    log "[INFO] iptables rules applied"
}

func_set_proxy() {
    log "[INFO] Initializing WARP + Redsocks proxy stack..."

    pkill -f warp-svc || true
    pkill -f warp-cli || true
    sleep 2

    func_start_warp
    func_check_warp
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
        log "[INFO] Global proxy via redsocks is working: $resp (via $checker)"
        touch /tmp/redsocks.ready
        return 0
    else
        log "[ERROR] Global proxy test failed"
        return 1
    fi
}

func_global_monitor() {
    while true; do
        log "[INFO] Cleaning up WARP and Redsocks..."
        pkill -f warp-svc || true
        pkill -f warp-cli || true
        pkill -f redsocks || true
        rm -f /tmp/redsocks.ready || true

        func_set_proxy || { sleep 60; continue; }

        proxy_fail_count=0
        while true; do
            sleep 180
            checker=$(printf "%s\n" $CHECKERS | shuf -n1)
            resp=$(curl -L --max-redirs 10 -s --max-time 30 "https://${checker}" 2>/dev/null | tr -d '\n\r' || true)
            if [ -n "$resp" ]; then
                log "[GOOD] Global monitor check OK: $resp (via $checker)"
                proxy_fail_count=0
            else
                proxy_fail_count=$((proxy_fail_count+1))
                log "[ERROR] Proxy failure detected (consecutive fails: ${proxy_fail_count})"
            fi
            if [ ${proxy_fail_count} -ge 3 ]; then
                log "[CRITICAL] Proxy failed 3 times in a row, restarting full stack..."
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
