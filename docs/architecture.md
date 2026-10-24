# Architecture

How a request travels from the internet to a self-hosted app, with the gateway VPS in front of Cloudflare's proxy
and the app at home behind NAT. Diagrams are [Mermaid](https://mermaid.js.org/) and render on GitHub.

## Overview

```mermaid
flowchart LR
    user(["Browser / app"])

    subgraph cf["Cloudflare (proxied, orange cloud)"]
        edge["Edge<br/>public TLS cert<br/>hides the VPS IP"]
    end

    subgraph vps["Gateway VPS (docker network: gateway)"]
        nginx["selfhosted-gateway (nginx)<br/>:443 stream: SNI preread, TLS passthrough,<br/>adds PROXY protocol<br/>:80 http: proxied to the link<br/>(redirects to https)"]
        glink["gateway-link<br/>container named after the domain<br/>(app.example.com → app-example-com)<br/>wg 10.0.0.1, DNAT 443→10.0.0.2:8443, 80→:8080"]
    end

    subgraph home["Home server (behind NAT, nothing exposed)"]
        clink["client-link (link service)<br/>wg 10.0.0.2<br/>Caddy :8443 PROXY protocol + TLS<br/>Caddy :8080 http"]
        app["app container<br/>(EXPOSE=app:port)"]
    end

    user -- "HTTPS<br/>TLS #1 (Cloudflare cert)" --> edge
    edge -- "HTTPS :443<br/>TLS #2 (origin cert)" --> nginx
    nginx -- "TCP passthrough<br/>by SNI → container name" --> glink
    glink <-. "WireGuard UDP, per-link port<br/>client dials out, keepalive 30s" .-> clink
    clink -- "plain HTTP<br/>compose network" --> app
```

TLS is terminated twice: Cloudflare terminates the browser's TLS, and opens a new TLS connection to the origin. The
gateway never decrypts anything on 443: nginx only reads the SNI to pick the gateway-link container, so the origin
TLS session ends in the home server's Caddy.

## One HTTPS request

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser
    participant CF as Cloudflare edge
    participant N as gateway nginx (stream :443)
    participant GL as gateway-link (app-example-com)
    participant CL as client-link Caddy (:8443)
    participant A as app

    B->>CF: TLS handshake, SNI app.example.com (Cloudflare edge cert)
    B->>CF: GET / (HTTP/2)
    CF->>N: TCP :443, TLS ClientHello SNI app.example.com
    Note over N: ssl_preread: map SNI → app-example-com:443<br/>resolved by Docker DNS (127.0.0.11)
    N->>GL: PROXY header (real client = Cloudflare IP) + raw TLS bytes
    Note over GL: iptables DNAT :443 → 10.0.0.2:8443<br/>SNAT → 10.0.0.1
    GL->>CL: same bytes, through the WireGuard tunnel
    Note over CL: listener_wrappers: proxy_protocol, then tls<br/>cert: TLS_CERT_FILE (Origin CA) / TLS_INTERNAL / ACME
    CL->>A: HTTP reverse_proxy EXPOSE (X-Forwarded-Proto: https)
    A-->>CL: response
    CL-->>CF: TLS #2 back through the tunnel and nginx
    CF-->>B: TLS #1
```

## Port 80

```mermaid
flowchart LR
    c(["client"]) -- "HTTP :80" --> h["nginx http server<br/>Host → http://app-example-com"]
    h -- "/.well-known/acme-challenge/*<br/>and everything else" --> l80["gateway-link :80<br/>DNAT → 10.0.0.2:8080"]
    l80 -- WireGuard --> caddy["client-link Caddy :8080<br/>redirects to https"]
```

Port 80 has no auth of its own: 443 is TLS passthrough, so a gateway login could only ever cover plain `http://`,
which the link redirects to https anyway. Turn on Cloudflare's "Always Use HTTPS" so clients never reach it.

## TLS on the link (client-link)

Cloudflare's proxy terminates TLS, so ACME's `tls-alpn-01` challenge can't reach the link, and `http-01` only works if
port 80 passes through untouched. A proxied link therefore needs a cert that doesn't depend on ACME.

| Mode | env | Cert | Cloudflare SSL mode | Survives restarts behind the proxy |
|---|---|---|---|---|
| ACME (default) | none | Let's Encrypt (ZeroSSL fallback) | Full (strict) | only while DNS-only (grey cloud) |
| Internal | `TLS_INTERNAL: true` | self-signed by Caddy | Full (not strict) | yes, but Cloudflare can't verify the origin |
| Mounted cert | `TLS_CERT_FILE`, `TLS_KEY_FILE` | e.g. Cloudflare Origin CA (wildcard, 15 years) | Full (strict) | yes |

```mermaid
flowchart TD
    start{"TLS_CERT_FILE set?"} -- yes --> mounted["tls $TLS_CERT_FILE $TLS_KEY_FILE<br/>no ACME"]
    start -- no --> internal{"TLS_INTERNAL set?"}
    internal -- yes --> selfsigned["tls internal<br/>self-signed"]
    internal -- no --> acme["automatic HTTPS<br/>ACME tls-alpn-01 / http-01"]
```

## Creating a link

```mermaid
sequenceDiagram
    autonumber
    participant U as make link (gateway-cli, local)
    participant G as gateway VPS (ssh)
    participant C as docker-compose.yml (home)

    U->>U: wg genkey → client keypair
    U->>G: ssh: remote.sh <container name> <client pubkey> gateway
    G->>G: docker run gateway-link -p 18521/udp (random host port), read the port
    G->>G: recreate it pinned to that port, generate the gateway keypair
    G-->>U: gateway pubkey + UDP port
    U-->>C: print the link service snippet<br/>(LINK_DOMAIN, EXPOSE, client privkey, gateway pubkey, GATEWAY_ENDPOINT)
    Note over C: docker compose up -d link<br/>keep the client private key out of git (.env)
```

- The SSH login uses the key given as `SSH_KEY` (mounted read-only for that run, never in the image) or the
  ssh-agent, and the port from `GATEWAY=host:port`. `~/.ssh/known_hosts` is mounted so a changed gateway host key is
  rejected. This login only creates links, the tunnel's security comes from the per-link WireGuard keys. With
  `gateway-link-command` as the key's forced command, the key can't do anything else on the gateway.
- The host part of `GATEWAY_ENDPOINT` is the SSH target's address (or `GATEWAY_ENDPOINT_HOST`), not the DNS of the
  link's domain: behind Cloudflare that would be a Cloudflare IP, and WireGuard has to reach the VPS directly.

## Naming

The domain maps to a container name on the `gateway` network, the same way for the stream (443) and http (80)
servers:

| Domain | Container |
|---|---|
| `example.com` | `example-com` |
| `app.example.com` | `app-example-com` |
| `x.app.example.com` | `x-app-example-com` |

## Hardening behind Cloudflare

- Only allow Cloudflare's IP ranges on 80/443 of the VPS (in the `DOCKER-USER` chain, ufw doesn't apply to published
  docker ports). Otherwise anyone can reach the origin directly and scanners can tie the domains to the VPS IP.
- Use Origin CA certs on the links (not in Certificate Transparency logs) and SSL mode Full (strict).
- Keep SSH and the per-link WireGuard UDP ports open.
- `http://<domain>/test` on port 80 reveals the routing target, block it if that matters.
