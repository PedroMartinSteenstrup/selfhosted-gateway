## Self-hosted Gateway

Fork of [fractalnetworks/selfhosted-gateway](https://github.com/fractalnetworks/selfhosted-gateway). It adds mounted
TLS certs on the link (e.g. Cloudflare Origin CA) and is tuned for a gateway VPS behind Cloudflare's proxy. See
[Fork changes](#fork-changes) and [Known issues](#known-issues) before deploying.

**Jump to [Getting Started](#getting-started)**

## Features and Benefits
- Docker native self-hosted alternative to Cloudflare Tunnels, Tailscale Funnel, ngrok and others.
- Entirely self-hosted and self-managed, includes local and remote tunneling components.
- No custom code, this project leverages existing battle tested FOSS components:
  - WireGuard
  - Nginx (Gateway)
  - Caddy (Client)
- TLS is terminated on the client (home) side, the gateway only routes by SNI and never decrypts traffic.
- Client side certs via Caddy's automatic HTTPS, a self-signed internal CA, or a mounted cert file.
- The gateway sends a PROXY protocol header on 443 so the link can see the client's IP (see [Known issues](#known-issues)).
- Optional basic authentication and mTLS on the client link.
- `FORWARD_ONLY` mode: raw TCP forwarding of 80/443 with socat, for an existing reverse proxy that does its own TLS.

## Video Overview & Setup Guide (upstream)
<a href="http://www.youtube.com/watch?feature=player_embedded&v=VCH8-XOikQc" target="_blank">
 <img src="http://img.youtube.com/vi/VCH8-XOikQc/0.jpg" alt="Watch the video" width="560" height="315" border="10" />
</a>

## Overview

This project automates the provisioning of **Reverse Proxy-over-VPN (RPoVPN)** WireGuard tunnels with Caddy and NGINX.
It is particularly well suited for exposing docker compose services to the public Internet. There's no code or APIs,
just a generic NGINX config and some short provisioning bash scripts.

Each exposed domain gets its own `link`: a WireGuard tunnel between a `gateway-link` container on the VPS and a
`client-link` container in your compose project. The client dials out, so nothing needs to be opened at home.

See [docs/architecture.md](docs/architecture.md) for diagrams of the whole request chain, the TLS modes and the
Cloudflare setup.

## Use cases

1. **RPoVPN is a common strategy for remotely accessing applications self-hosted at home. It solves problems such as:**
  - Self-hosting behind double-NAT or via an ISP that does CGNAT (Starlink, Mobile Internet).
  - Inability to portforward on your local network due to insufficient access.
  - Having a dynamically allocated IP that may change frequently.

2. **Using RPoVPN is ideal for self-hosting from both a network security and privacy perspective:**
  - Obviates the need for a static IP or expose your home's public IP address to the world.
  - Utilizes advanced network isolation capabilities of Docker (thanks to Linux network namespaces) in order to isolate locally exposed services from your home network and other local docker services.
  - Built on open-source technologies (WireGuard, Caddy and NGINX).

## Getting Started

### Prerequisites
- Domain
  - Ability to create `A` records (and optionally `AAAA`) for the domain.
- Gateway
  - A publicly addressable Linux host to act as the `gateway`, typically a cloud VPS (Hetzner, Digital Ocean, etc..) with:
  - SSH access, ideally with a dedicated key (see [Gateway SSH key](#gateway-ssh-key))
  - Ports 80/443 open (http/https)
  - The UDP port range listed by `cat /proc/sys/net/ipv4/ip_local_port_range` open to the Internet (one random
    port per link, for WireGuard).
  - `docker`, `git` & `make` installed
- Client
  - An existing `docker-compose.yml` that you would like to expose to the Internet.
  - `docker`, `git` & `make` installed locally
  - An SSH key that can log in to the gateway: a key file passed as `SSH_KEY`, or a key loaded in `ssh-agent`.

### Steps
#### Gateway
1. Point `*.mydomain.com` (DNS A record) to the IP address of your VPS gateway host.

2. Connect to the `gateway` via SSH and set up the `gateway` service:
```console
foo@gateway:~$ git clone ... && cd selfhosted-gateway
foo@gateway:~/selfhosted-gateway$ make setup     # creates the `gateway` docker network
foo@gateway:~/selfhosted-gateway$ make gateway   # builds all images, then starts nginx
```
`make gateway` publishes 80, 443 and 5201 (iperf3, for testing link throughput) and mounts `/var/log/nginx` from the
host (for fail2ban).

#### Client
3. Build the images, then create the link from the `client`. This logs in to the gateway over SSH (see
   [Gateway SSH key](#gateway-ssh-key)), starts the gateway-link container there and prints a compose snippet:
```console
foo@local:~$ git clone ... && cd selfhosted-gateway
foo@local:~/selfhosted-gateway$ make docker
foo@local:~/selfhosted-gateway$ make link GATEWAY=root@203.0.113.10:22 SSH_KEY=~/.ssh/gateway_ed25519 FQDN=nginx.mydomain.com EXPOSE=nginx:80
# docker compose --env-file ./nginx-mydomain-com.env ...
  link:
    image: fractalnetworks/gateway-client:latest
    environment:
      LINK_DOMAIN: nginx.mydomain.com
      EXPOSE: nginx:80
      GATEWAY_CLIENT_WG_PRIVKEY: 4M7Ap0euzTxq7gTA/WIYIt3nU+i2FvHUc9eYTFQ2CGI=
      GATEWAY_LINK_WG_PUBKEY: Wipd6Pv7ttmII4/Oj82I5tmGZwuw6ucsE3G+hwsMR08=
      GATEWAY_ENDPOINT: 203.0.113.10:49185
      # Remove following to disable basic authentication
      BASIC_AUTH: admin:admin
      # Remove following line to get certs from Let's Encrypt
      TLS_INTERNAL: true
      # CADDY_TLS_PROXY: true
      # CADDY_TLS_INSECURE: true
      # FORWARD_ONLY: true
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
...
```
   On macOS (Docker Desktop) use `make link-macos` instead, it mounts Docker Desktop's SSH agent socket.

   It also writes the link's values to `./nginx-mydomain-com.env`, owner-only (`600`) and owned by you:
```console
foo@local:~/selfhosted-gateway$ cat ./nginx-mydomain-com.env
EXPOSE=nginx:80
GATEWAY_ENDPOINT=203.0.113.10:49185
GATEWAY_LINK_WG_PUBKEY=Wipd6Pv7ttmII4/Oj82I5tmGZwuw6ucsE3G+hwsMR08=
LINK_DOMAIN=nginx.mydomain.com
GATEWAY_CLIENT_WG_PRIVKEY=4M7Ap0euzTxq7gTA/WIYIt3nU+i2FvHUc9eYTFQ2CGI=
```
   It holds the client's WireGuard private key: keep it out of git.

   **Review before using it:**
   - The snippet turns on `BASIC_AUTH: admin:admin` and `TLS_INTERNAL: true` (a self-signed cert). Change or remove
     both, see [Client link configuration](#client-link-configuration) for the TLS options.
   - The host in `GATEWAY_ENDPOINT` is the address of `GATEWAY` (the ssh target), not the DNS of `FQDN`, which is a
     Cloudflare IP when the domain is proxied. If you reach the gateway's ssh through another address, set
     `GATEWAY_ENDPOINT_HOST=<VPS IP>`.

4. Add the `link` service to your `docker-compose.yml`. The `.env` uses exactly the variable names the link reads, so
   the simplest is to copy it next to the compose file as `link.env` and load it with `env_file`. Your compose file
   then holds no keys or ports, and re-linking only replaces that file:
    ```yaml
    services:
      nginx:
        image: nginx:latest
      link:
        image: fractalnetworks/gateway-client:latest
        env_file:
          - link.env   # LINK_DOMAIN, EXPOSE, GATEWAY_*, the WireGuard key: from make link
        environment:   # anything else, e.g. the TLS mode. Don't repeat link.env's variables here, they'd win
          TLS_CERT_FILE: /certs/origin.pem
          TLS_KEY_FILE: /certs/origin.key
        restart: unless-stopped
        cap_add:
          - NET_ADMIN
        volumes:
          - ./certs:/certs:ro
          - caddy_data:/data   # keeps certs across restarts
    volumes:
      caddy_data:
    ```
   Pasting the printed snippet into `environment:` works as well, but then the private key is in your compose file.

   The images are built locally under the upstream `fractalnetworks/*` names. Run `make docker` on every host that
   uses them (or build `src/client-link` alone on the client), as pulling `fractalnetworks/gateway-client:latest`
   from Docker Hub gets upstream's image without this fork's changes.

5. Start your docker compose project as you would normally (`docker compose up -d`).

This establishes the `link` to the `gateway` and provisions a TLS certificate.
**You may repeat steps 3-5 for as many services as you would like to expose using the same gateway**

### Gateway SSH key

`make link` logs in to the gateway over SSH to create the gateway-link container, so whoever holds that login can
add links (and run docker) on the gateway. Use a dedicated key for it:

- `SSH_KEY=<path>` mounts the key read-only into the `gateway-cli` container for that one run. It is never copied
  into the image or the repo, and only that key is offered (`IdentitiesOnly`).
- **Key in an ssh agent** (1Password, a passphrase-protected key, a hardware key): point `SSH_KEY` at the *public*
  key. ssh then asks the forwarded agent to sign with that key only, and the private key never touches the disk. The
  agent is the one in `SSH_AUTH_SOCK`.
- Without `SSH_KEY`, every key in your `ssh-agent` is offered.
- The SSH port goes in `GATEWAY`: `GATEWAY=root@203.0.113.10:2220`.
- `~/.ssh/known_hosts` is mounted read-only (override with `KNOWN_HOSTS=<path>`). A gateway whose host key changed is
  rejected, an unknown one is trusted on first use. Use the same host name you ssh to, so the entry matches.

Put per-machine defaults in a gitignored `local.mk` instead of repeating them, e.g. with the key in 1Password:
```make
GATEWAY = fief@gateway.example.com:2220
SSH_KEY = ~/.ssh/gateway_link.pub
# 1Password's agent, when your shell's SSH_AUTH_SOCK is another agent
export SSH_AUTH_SOCK := $(HOME)/.1password/agent.sock
```

The SSH key only protects link *creation*. The tunnel itself is secured by the per-link WireGuard keys, which
`make link` generates fresh each time and which never leave the two link containers and your `.env`.

#### Restrict the key to link creation

The SSH user on the gateway can run docker, which makes any login root-equivalent. Pin the `make link` key to
[`gateway-link-command`](src/create-link/gateway-link-command.sh), so that key can only create *new* links. No shell,
no other docker command, and existing links can't be replaced (removing a link still needs your admin login):

```console
# on the gateway, as root, from the repo checkout
install -D -m 755 src/create-link/remote.sh /usr/local/lib/selfhosted-gateway/remote.sh
install -m 755 src/create-link/gateway-link-command.sh /usr/local/sbin/gateway-link-command
# ~/.ssh/authorized_keys of the ssh user, one line:
command="/usr/local/sbin/gateway-link-command",restrict ssh-ed25519 AAAA... make link
```

The script only accepts the exact command `make link` sends, checks the link name, WireGuard key and network, and
runs its own root-owned copy of `remote.sh`, ignoring what the client sends. `restrict` turns off pty, port, agent and
X11 forwarding. Add `from="<your IP>"` too if your home IP is static. CI runs its simulated gateway the same way and
checks that other commands are refused.

### Automating links

`make link` needs no input apart from the agent's approval of the key, so it can run from a provisioning tool. The
contract is the `.env` file:

- Run the `fractalnetworks/gateway-cli` container the way the `link` target does, without `-t`, and with
  `-e WORKDIR_OWNER=<uid>:<gid>` so the file is owned by the user running the tool. The file is written to the
  directory mounted at `/workdir`, named after the domain (`app.example.com` → `app-example-com.env`).
- Keep that file as the link's source of truth and copy it to the client as `link.env`.
- The gateway-link holds the other half of the keys inside its container, without a volume. If it's removed (or the
  gateway rebuilt), or the `.env` is lost, the link can't be repaired: remove the gateway-link with an admin login
  and run `make link` again, which creates new keys on both ends.

## Client link configuration

Environment variables of the `link` service (`fractalnetworks/gateway-client`):

| Variable | Required | Description |
|---|---|---|
| `LINK_DOMAIN` | yes | Public domain of the service. Must match the gateway-link container name (dots → dashes). |
| `EXPOSE` | yes | Upstream to proxy to, `service:port`. With `CADDY_TLS_PROXY`, e.g. `https://service:443`. |
| `GATEWAY_CLIENT_WG_PRIVKEY` | yes | Client WireGuard private key (generated by `make link`). |
| `GATEWAY_LINK_WG_PUBKEY` | yes | Gateway-link WireGuard public key (generated by `make link`). |
| `GATEWAY_ENDPOINT` | yes | `<VPS IP>:<UDP port>` of the gateway-link. |
| `LINK_MTU` | no | WireGuard MTU, default `1380`. Lower it if connections stall. |
| `BASIC_AUTH` | no | `user:password` in plain text. It is hashed at startup. The password must not contain `:`. |
| `TLS_CERT_FILE`, `TLS_KEY_FILE` | no | Paths (inside the container) of a mounted cert and key. Skips ACME. Set both. |
| `TLS_INTERNAL` | no | Any value: use a self-signed cert from Caddy's internal CA. |
| `TLS_INTERNAL_CONFIG` | no | Raw Caddy `tls` block, e.g. for mTLS. Overwritten if `TLS_CERT_FILE` or `TLS_INTERNAL` is set. |
| `CADDY_TLS_PROXY` | no | Any value: talk TLS to the upstream. |
| `CADDY_TLS_INSECURE` | no | Any value: skip upstream cert verification (with `CADDY_TLS_PROXY`). |
| `FORWARD_ONLY` | no | Any value: disable Caddy and forward raw TCP with socat. |
| `EXPOSE_HTTPS` | with `FORWARD_ONLY` | `service:port` that receives the 443 traffic. |

The boolean-style variables are checked for being *set*, not for their value, so `TLS_INTERNAL: false` also turns
the option on. Remove the line to turn it off.

### TLS certificates

The link picks the first matching mode:

1. `TLS_CERT_FILE` + `TLS_KEY_FILE`: a mounted cert, no ACME.
2. `TLS_INTERNAL`: a self-signed cert.
3. Otherwise ACME (Let's Encrypt, ZeroSSL fallback) via Caddy's automatic HTTPS.

ACME only works while the domain resolves straight to the VPS. Behind Cloudflare's proxy, use a Cloudflare Origin CA
cert with SSL mode "Full (strict)":

```yaml
  link:
    environment:
      TLS_CERT_FILE: /certs/origin.pem
      TLS_KEY_FILE: /certs/origin.key
    volumes:
      - ./certs:/certs:ro
```

[docs/architecture.md](docs/architecture.md#tls-on-the-link-client-link) compares the modes for each Cloudflare SSL setting.

### Split DNS without SSL Termination

In the event you already have a reverse proxy which performs SSL termination for your apps/services you can enable `FORWARD_ONLY` mode. Suppose you are using Traefik for SSL termination:

1. On your local LAN you will resolve \*.sub.mydomain.com to your local Traefik IP
2. On your external DNS for your domain you will resolve \*.sub.mydomain.com to the IP of your VPS
3. In your compose file add an additional two variables: `EXPOSE_HTTPS` and `FORWARD_ONLY`

```yaml
services:
  app:
    image: traefik:latest
  link:
    image: fractalnetworks/gateway-client:latest
    environment:
      LINK_DOMAIN: sub.mydomain.com
      EXPOSE: app:80
      EXPOSE_HTTPS: app:443
      FORWARD_ONLY: "True"
      GATEWAY_CLIENT_WG_PRIVKEY: 4M7Ap0euzTxq7gTA/WIYIt3nU+i2FvHUc9eYTFQ2CGI=
      GATEWAY_LINK_WG_PUBKEY: Wipd6Pv7ttmII4/Oj82I5tmGZwuw6ucsE3G+hwsMR08=
      GATEWAY_ENDPOINT: 203.0.113.10:49185
    cap_add:
      - NET_ADMIN
```
The gateway prepends a PROXY protocol header to every 443 connection, so the 443 entrypoint of your proxy must
accept PROXY protocol (in Traefik: `entryPoints.<name>.proxyProtocol.trustedIPs`, with the link's IP).

You will see logs from the link container indicating it is in forward only mode:
```
traefikv2_link.1.qvijxtwiu0wb@docker01    | + socat TCP4-LISTEN:8443,fork,reuseaddr TCP4:app:443,reuseaddr
traefikv2_link.1.qvijxtwiu0wb@docker01    | + socat TCP4-LISTEN:8080,fork,reuseaddr TCP4:app:80,reuseaddr
```

### TLS Backend

If the backend container serves TLS itself, set `CADDY_TLS_PROXY` so Caddy connects to it over HTTPS. If its
certificate is self-signed, also set `CADDY_TLS_INSECURE` to skip verification.

Caddy still provisions the public certificate for `LINK_DOMAIN` as usual.

```yaml
services:
  app:
    image: traefik:latest
  link:
    image: fractalnetworks/gateway-client:latest
    environment:
      LINK_DOMAIN: sub.mydomain.com
      EXPOSE: https://app:443
      CADDY_TLS_PROXY: true
      # Optional
      # CADDY_TLS_INSECURE: true
      GATEWAY_CLIENT_WG_PRIVKEY: 4M7Ap0euzTxq7gTA/WIYIt3nU+i2FvHUc9eYTFQ2CGI=
      GATEWAY_LINK_WG_PUBKEY: Wipd6Pv7ttmII4/Oj82I5tmGZwuw6ucsE3G+hwsMR08=
      GATEWAY_ENDPOINT: 203.0.113.10:49185
    cap_add:
      - NET_ADMIN
```

### mTLS (client authentication)

It is possible to use Mutual TLS authentication for client connections, which is useful to prevent MITM attacks and reducing attack vector when running possibly insecure software in your containers.

You will need to create a self-signed CA certificate and sign X.509 client certificates, then use this snippet for your `compose.yaml`
```yaml
      TLS_INTERNAL_CONFIG: |2
        tls {
                client_auth {
                    mode require_and_verify
                    trust_pool inline {
                        trust_der YOUR_BASE64_ENCODED_CA_IN_DER_FORMAT_BELONGS_HERE
                    }
                }
            }
```

 or this for your `.env` file:
```yaml
TLS_INTERNAL_CONFIG='tls {
        client_auth {
            mode require_and_verify
            trust_pool inline {
                trust_der YOUR_BASE64_ENCODED_CA_IN_DER_FORMAT_BELONGS_HERE
            }
        }
    }'
```

Remove `TLS_INTERNAL` (which the generated snippet sets) and `TLS_CERT_FILE`, otherwise they replace this block.

Now you won't be able to establish connections to your service without your client certificate. There are other possible configuration values, of course, please have a look at the official [Caddy documentation](https://caddyserver.com/docs/caddyfile/directives/tls#client_auth).

Keep in mind, this might affect any corporate firewall as there is no way to terminate TLS without breaking client authentication and therefore no way to connect for a client behind one of these appliances.

## Gateway operations

### Show all links running on a Gateway
Each link is a `gateway-link` container named after its domain (`app.example.com` → `app-example-com`):
```
$ docker ps --filter ancestor=fractalnetworks/gateway-link:latest
```

### Remove a link
On the gateway, with an admin login (the restricted `make link` key can't remove links):
```
$ docker rm -f app-example-com
```
Then stop the `link` service on the client and delete its `.env`.

### Restricting 80/443 to Cloudflare
If the gateway sits behind Cloudflare's proxy, only allow Cloudflare's ranges on 80/443, otherwise the origin can be
reached (and identified) directly. Published docker ports bypass ufw, so filter in the `DOCKER-USER` chain, and match
only connections opened from outside:
```console
iptables -I DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 443 --ctdir ORIGINAL -j CLOUDFLARE-ONLY
```
Without `--ctdir ORIGINAL`, the replies to the containers' own outbound https connections match too (their original
destination port is also 443), and containers on the gateway can't reach the internet, e.g. `apk` in docker builds
fails with `TLS: unspecified error`.

### Debug routing
`http://<any domain>/test` on port 80 answers with the container name the gateway would route to. It is public, so
block it if you don't want domain-to-container mapping exposed.

### Logs
nginx writes `/var/log/nginx/access.log` and `error.log`, mounted on the host for fail2ban.

## Make targets

| Target | Where | What |
|---|---|---|
| `make docker` | both | Build all four images under the `fractalnetworks/*:latest` names. |
| `make setup` | gateway | Create the `gateway` docker network. |
| `make gateway` | gateway | Build, then run the nginx gateway (80, 443, 5201). |
| `make link GATEWAY=user@host[:port] [SSH_KEY=path] FQDN=... EXPOSE=svc:port` | client | Create a gateway-link over SSH and print the client snippet. |
| `make link-macos ...` | client | Same, using Docker Desktop's SSH agent socket. |
| `make link-ci` | CI | End-to-end test with a simulated gateway (see `ci/`). |

`GATEWAY_NETWORK=<name>` overrides the docker network name for `setup` and `link`. `GATEWAY`, `SSH_KEY` and
`KNOWN_HOSTS` can be set in a gitignored `local.mk`.

## Repository layout

```shell
├── ci/              # end-to-end test: simulated sshd gateway + nginx gateway + test link
├── docs/            # architecture.md, diagrams of the request chain
├── examples/ssh/    # proxying SSH through the gateway (FORWARD_ONLY + openssl s_client)
└── src
    ├── client-link  # WireGuard + Caddy on the client. TLS termination, basic auth, socat forward mode.
    ├── create-link  # CLI (`make link`): generates keys, runs remote.sh on the gateway over SSH, prints the snippet.
    ├── gateway      # NGINX: SNI passthrough on 443 (+PROXY protocol), Host-based proxy on 80.
    └── gateway-link # WireGuard + iptables DNAT on the gateway, one container per link.
```

### Terminology
- `Link` - A dedicated WireGuard tunnel between a local container (client) and the remote container running on the Gateway through which Reverse Proxy traffic is routed. A link is comprised of 2 pieces, the local or client link and the gateway or remote link.

## Fork changes

Compared to upstream:
- `TLS_CERT_FILE` / `TLS_KEY_FILE` on the client link for a mounted cert (e.g. Cloudflare Origin CA).
- No basic auth on the gateway's port 80.
- The gateway image is pinned to `nginx:1.29-bookworm`, logs to files for fail2ban, and publishes iperf3 on 5201.
- `make link` takes a dedicated SSH key (`SSH_KEY`, a private key or the public half of an agent's key), mounted at
  run time, and checks `known_hosts`.
- `gateway-link-command`: forced command that restricts the `make link` key to creating links.
- `GATEWAY_ENDPOINT` comes from the ssh target, not the domain's DNS (a Cloudflare IP when proxied).
- The link `.env` is written `600` and owned by the caller.
- Client link on `caddy:2.10`, Dependabot for the base images and actions.

## Known issues

- **Client IP:** the app sees the link's tunnel address (`10.0.0.1`) in `X-Forwarded-For`, not the client's IP:
  the PROXY protocol header the gateway sends on 443 doesn't take effect in the link's Caddy (seen with Caddy 2.8 and
  2.10). Behind Cloudflare, use the `CF-Connecting-IP` header instead.
- **`link-compose-snippet.yml`** reads `${WG_PRIVKEY}` while the `.env` names it `GATEWAY_CLIENT_WG_PRIVKEY`: use the
  `.env` with `env_file` (step 4), not the template with `--env-file`.
- **Generic UDP proxying is not reachable.** `gateway-link` relays UDP 18522/18523 to the client, but only the
  WireGuard port is published on the gateway.

## FAQ

- How is this better than setting up nginx and WireGuard myself on a VPS?

The goal of this project is to make self-hosting more accessible and reproducible. This project leverages a "ZeroTrust" network architecture. Each "Link" provides a dedicated WireGuard tunnel that is isolated from other containers and the underlying host. This isolation is provided by Docker Compose's creation of a private Docker network for each compose project.

- Can I still access the service from my local network?

Yes, just expose ports in your Docker host as you would normally:
```
ports:
 - 80:80
 - 443:443
```

## Support

Upstream community support is available via the Fractal Networks Matrix channel https://matrix.to/#/#fractal:ether.ai
