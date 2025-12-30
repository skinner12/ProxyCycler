# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ProxyCycler is a Docker-based Squid proxy server that rotates through a list of upstream proxies using round-robin load balancing. It acts as a local proxy (port 3128) that distributes outgoing requests across multiple external proxies.

## Commands

### Generate Squid Configuration
```bash
./generate_squid_conf.sh
```
Reads `proxy.txt` and generates `squid.conf` with cache_peer entries for each proxy.

### Start Proxy Server
```bash
docker-compose up -d
```

### Restart After Config Changes
```bash
docker-compose restart squid
```

### Stop Proxy Server
```bash
docker-compose down
```

## Architecture

### Configuration Flow
1. `proxy.txt` - Source of upstream proxies (format: `username:password:ip:port`)
2. `generate_squid_conf.sh` - Bash script that parses proxy.txt and generates squid.conf
3. `squid.conf` - Generated Squid configuration with round-robin cache_peer entries
4. Docker container mounts squid.conf and runs Squid proxy

### Key Files
- `proxy.txt` - Upstream proxy credentials (gitignored)
- `squid.conf` - Generated config (gitignored) - never edit directly
- `generate_squid_conf.sh` - Configuration generator script
- `docker-compose.yml` - Container definition using b4tman/squid image

### Squid Configuration Pattern
The generator creates `cache_peer` directives with `round-robin` flag, ensuring traffic is distributed across all configured upstream proxies. The `never_direct allow all` directive forces all traffic through the upstream proxies.
