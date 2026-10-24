FROM alpine:latest

RUN apk add gettext openssh-client wireguard-tools;

# the gateway ssh key and known_hosts are mounted at run time (see `make link`), never baked into the image
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

COPY . /code

WORKDIR /code

# save created snippet variables to `/workdir/subdomain-domain-tld.env`
VOLUME /workdir

ENTRYPOINT ["/code/entrypoint.sh"]
