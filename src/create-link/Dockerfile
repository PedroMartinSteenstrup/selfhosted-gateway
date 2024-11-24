FROM alpine:latest

RUN apk add gettext openssh-client wireguard-tools;

RUN mkdir -p /root/.ssh
COPY raspi2staging /root/.ssh/raspi2staging

RUN chmod 600 /root/.ssh/
RUN ssh-keygen -y -f /root/.ssh/raspi2staging

COPY . /code

WORKDIR /code

# save created snippet variables to `/workdir/subdomain-domain-tld.env`
VOLUME /workdir

ENTRYPOINT ["/code/entrypoint.sh"]
