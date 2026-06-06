# Docker-Warp-Redsocks

Docker base image that runs any application behind a transparent proxy stack — Cloudflare WARP + Redsocks + iptables.

## Variants

| Image | Base | Size |
|-------|------|------|
| `ghcr.io/techroy23/docker-warp-redsocks:alpine` | Alpine Linux | Lightweight |
| `ghcr.io/techroy23/docker-warp-redsocks:ubuntu` | Ubuntu 24.04 | Heavier, official WARP deb |

## How it works

1. WARP client starts, exposes a SOCKS5 proxy on port `40000`
2. Redsocks listens on port `50000`, forwarding all TCP to WARP's SOCKS5
3. iptables `OUTPUT` chain redirects all outbound TCP traffic (except localhost, DNS, proxy ports) to Redsocks
4. A monitor loop checks connectivity every 3 minutes, restarts the stack on 3 consecutive failures
5. Ready signal: `/tmp/redsocks.ready` is created once the proxy is verified working

## Usage

### 1. Import in your Dockerfile

```dockerfile
FROM ghcr.io/techroy23/docker-warp-redsocks:alpine
# or
# FROM ghcr.io/techroy23/docker-warp-redsocks:ubuntu

COPY . /app
```

### 2. Run with required capabilities

```bash
docker run -it --rm \
  --sysctl net.ipv4.ip_forward=1 \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  yourimage:latest
```

### 3. Start proxy in your entrypoint

```bash
#!/bin/bash
set -e

/app/__setup_proxy.sh &

while [ ! -f /tmp/redsocks.ready ]; do
    sleep 5
done

echo "Proxy ready!"
exec ./your_program
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `WARP_PORT` | `40000` | WARP SOCKS5 proxy port |
| `REDSOCKS_PORT` | `50000` | Redsocks transparent proxy port |
| `WARP_MODE` | `proxy` | WARP mode: `proxy`, `warp`, or `gateway` |
| `SHOW_LOGS` | `false` | Show Redsocks logs on stderr |

```bash
# Warp mode
docker run -e WARP_MODE=warp yourimage

# Show debug logs
docker run -e SHOW_LOGS=true yourimage

# Custom ports
docker run -e WARP_PORT=40001 -e REDSOCKS_PORT=50001 yourimage
```

## Requirements

- `NET_ADMIN` and `NET_RAW` capabilities
- `net.ipv4.ip_forward=1` sysctl
- First run: WARP registration is automatic
- WARP Terms of Service acceptance is automatic
