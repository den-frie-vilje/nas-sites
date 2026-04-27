# Webhook receiver image.
#
# adnanh/webhook's official image (via almir/webhook) is built
# FROM scratch — no shell, no utilities — so we can't install
# packages on top of it directly. Multi-stage build: grab just
# the webhook binary from that image, then COPY it into an
# alpine base that has the docker-cli + git + curl + bash we
# need for the deploy hook scripts.
#
# Built in CI (not on NAS — see webhook-image.yml) because
# Synology's kernel ships without seccomp support, breaking
# any RUN step during an in-place docker build on DSM.

FROM almir/webhook:2.8.3@sha256:f77cc91c91d1527b48052280af38b50791e842ad8dd291e9b360a0c13c9ca991 AS webhook-binary

FROM alpine:3.23@sha256:5b10f432ef3da1b8d4c7eb6c487f2f5a8f096bc91145e68878dd4a5019afde11

RUN apk add --no-cache \
    docker-cli \
    docker-cli-compose \
    git \
    bash \
    curl

COPY --from=webhook-binary /usr/local/bin/webhook /usr/local/bin/webhook

ENTRYPOINT ["/usr/local/bin/webhook"]
