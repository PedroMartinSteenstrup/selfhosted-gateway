.PHONY: docker link link-macos setup gateway link-ci

GATEWAY_NETWORK=gateway

# per-machine defaults (GATEWAY, SSH_KEY, ...), gitignored, e.g. `SSH_KEY=~/.ssh/raspi2staging`
-include local.mk

# dedicated ssh key for the gateway, mounted read-only into gateway-cli at run time, never built into the image.
# Empty: use the ssh-agent only. The ssh port goes in GATEWAY, e.g. GATEWAY=root@1.2.3.4:2220
SSH_KEY ?=
KNOWN_HOSTS ?= $(HOME)/.ssh/known_hosts
SSH_KEY_FILE := $(wildcard $(SSH_KEY))
KNOWN_HOSTS_FILE := $(wildcard $(KNOWN_HOSTS))
CHECK_SSH_KEY = $(if $(SSH_KEY),$(if $(SSH_KEY_FILE),,@echo "SSH_KEY=$(SSH_KEY) not found" && exit 1))
LINK_MOUNTS = -v "$$PWD:/workdir" \
	$(if $(SSH_KEY_FILE),-v "$(abspath $(SSH_KEY_FILE)):/run/secrets/ssh_key:ro") \
	$(if $(KNOWN_HOSTS_FILE),-v "$(abspath $(KNOWN_HOSTS_FILE)):/run/secrets/known_hosts:ro")

docker:
	docker build -t fractalnetworks/selfhosted-gateway:latest ./src/gateway/
	docker build -t fractalnetworks/gateway-link:latest ./src/gateway-link/
	docker build -t fractalnetworks/gateway-client:latest ./src/client-link/
	docker build -t fractalnetworks/gateway-cli:latest ./src/create-link/

setup:
	docker network create $(GATEWAY_NETWORK)

gateway: docker
	docker run --network $(GATEWAY_NETWORK) --restart unless-stopped -p 80:80 -p 443:443 -p 5201:5201 -v /var/log/nginx:/var/log/nginx:rw -e NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx -it -d fractalnetworks/selfhosted-gateway:latest

link:
	$(CHECK_SSH_KEY)
	docker run -e GATEWAY_NETWORK=$(GATEWAY_NETWORK) -e WORKDIR_OWNER=$$(id -u):$$(id -g) $(if $(GATEWAY_ENDPOINT_HOST),-e GATEWAY_ENDPOINT_HOST=$(GATEWAY_ENDPOINT_HOST)) $${SSH_AUTH_SOCK:+-e SSH_AUTH_SOCK=$$SSH_AUTH_SOCK -v $$SSH_AUTH_SOCK:$$SSH_AUTH_SOCK} $(LINK_MOUNTS) --rm -it fractalnetworks/gateway-cli:latest $(GATEWAY) $(FQDN) $(EXPOSE)

link-macos:
	$(CHECK_SSH_KEY)
	docker run -v /run/host-services/ssh-auth.sock:/run/host-services/ssh-auth.sock -e GATEWAY_NETWORK=$(GATEWAY_NETWORK) -e WORKDIR_OWNER=$$(id -u):$$(id -g) $(if $(GATEWAY_ENDPOINT_HOST),-e GATEWAY_ENDPOINT_HOST=$(GATEWAY_ENDPOINT_HOST)) -e SSH_AUTH_SOCK="/run/host-services/ssh-auth.sock" $(LINK_MOUNTS) --rm -it fractalnetworks/gateway-cli:latest $(GATEWAY) $(FQDN) $(EXPOSE)

link-ci:
	./ci/create-link-ci.sh $(GATEWAY) $(FQDN) nginx:80
