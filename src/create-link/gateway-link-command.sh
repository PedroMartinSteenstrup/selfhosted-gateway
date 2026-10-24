#!/bin/bash
# Forced command for the `make link` ssh key on the gateway, so that key can only create links:
#   command="/usr/local/sbin/gateway-link-command",restrict ssh-ed25519 AAAA... make link
# (`command="/usr/local/sbin/gateway-link-command <network>"` if the gateway network isn't called `gateway`)
#
# The client's command must be exactly `bash -s -- <container name> <wireguard pubkey> <network>`, as sent by
# create-link/entrypoint.sh. Its stdin (the client's copy of remote.sh) is ignored: the root-owned copy installed
# next to this script runs instead. Existing containers can't be replaced, `docker run --name` refuses, so removing
# or recreating a link still needs an admin login.

set -euo pipefail

REMOTE_SH=/usr/local/lib/selfhosted-gateway/remote.sh
ALLOWED_NETWORK=${1:-gateway}

deny() {
    echo "gateway-link-command: $1" >&2
    exit 1
}

read -r -a ARGS <<< "${SSH_ORIGINAL_COMMAND:-}"
if [[ ${#ARGS[@]} -ne 6 || ${ARGS[0]} != bash || ${ARGS[1]} != -s || ${ARGS[2]} != -- ]]; then
    deny "this key can only create links"
fi

CONTAINER_NAME=${ARGS[3]}
LINK_CLIENT_WG_PUBKEY=${ARGS[4]}
GATEWAY_NETWORK=${ARGS[5]}

# FQDN with dots as dashes, lowercase (create-link/entrypoint.sh)
[[ $CONTAINER_NAME =~ ^[a-z0-9]([a-z0-9-]{0,251}[a-z0-9])?$ ]] || deny "invalid link name: $CONTAINER_NAME"
# 32 bytes of base64, as printed by `wg pubkey`
[[ $LINK_CLIENT_WG_PUBKEY =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]] || deny "invalid wireguard public key"
[[ $GATEWAY_NETWORK == "$ALLOWED_NETWORK" ]] || deny "network must be $ALLOWED_NETWORK"

exec bash "$REMOTE_SH" "$CONTAINER_NAME" "$LINK_CLIENT_WG_PUBKEY" "$GATEWAY_NETWORK" < /dev/null
