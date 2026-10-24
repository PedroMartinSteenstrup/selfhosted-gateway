# simulated gateway host: sshd with the docker socket, the CI key restricted to link creation like on a real gateway
# (build context is the repo root, see docker-compose.yaml)
FROM alpine:latest
RUN apk add openssh-server bash docker-cli curl
RUN ssh-keygen -A

COPY src/create-link/remote.sh /usr/local/lib/selfhosted-gateway/remote.sh
COPY src/create-link/gateway-link-command.sh /usr/local/sbin/gateway-link-command
COPY ci/gateway-sim-key.pub /tmp/gateway-sim-key.pub
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh \
    && echo "command=\"/usr/local/sbin/gateway-link-command\",restrict $(cat /tmp/gateway-sim-key.pub)" > /root/.ssh/authorized_keys

ENTRYPOINT [ "/usr/sbin/sshd", "-D", "-e" ]
