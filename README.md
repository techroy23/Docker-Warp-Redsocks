# Docker-Warp-Redsocks

Docker base image that routes all outbound traffic through Cloudflare WARP via a transparent proxy stack.

## Variants

| Image | Base |
|-------|------|
| `ghcr.io/techroy23/docker-warp-redsocks:alpine` | Alpine Linux |
| `ghcr.io/techroy23/docker-warp-redsocks:ubuntu` | Ubuntu 24.04 |

## How it works

1. Cloudflare WARP starts and binds a SOCKS5 proxy to `127.0.0.1:40000`
2. Socat opens `0.0.0.0:40001` so external hosts can also use WARP as a SOCKS5 proxy
3. Redsocks listens on `127.0.0.1:50000` and forwards all traffic to WARP's SOCKS5
4. iptables `OUTPUT` chain redirects all outbound TCP (except localhost, DNS, and proxy ports) to Redsocks
5. A monitor loop checks connectivity every 3 minutes and restarts the stack after 3 consecutive failures
6. Ready signal: `/tmp/redsocks.ready` is created once everything is verified working

## Usage

### 1. Import in your Dockerfile

```dockerfile
FROM ghcr.io/techroy23/docker-warp-redsocks:alpine

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
| `SHOW_LOGS` | `false` | Show Redsocks logs on stderr |

```bash
docker run -e SHOW_LOGS=true yourimage
```

## Requirements

- `NET_ADMIN` and `NET_RAW` capabilities
- `net.ipv4.ip_forward=1` sysctl
- First run: WARP registration is automatic
- WARP Terms of Service acceptance is automatic
