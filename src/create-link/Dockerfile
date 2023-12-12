FROM alpine:latest

RUN apk add gettext openssh-client wireguard-tools python3;

RUN mkdir -p /root/.ssh
COPY raspi2staging /root/.ssh/raspi2staging

RUN chmod 600 /root/.ssh/
RUN ssh-keygen -y -f /root/.ssh/raspi2staging

COPY . /code

WORKDIR /code

ENTRYPOINT ["/code/entrypoint.sh"]
