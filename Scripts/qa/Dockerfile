FROM debian:bookworm-slim

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        dovecot-core \
        dovecot-imapd \
        openssl \
        ca-certificates \
        netcat-openbsd \
        procps \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd -g 5000 vmail \
    && useradd -u 5000 -g vmail -d /var/mail/qa -s /usr/sbin/nologin vmail \
    && mkdir -p /var/mail/qa /run/dovecot /etc/dovecot/certs

COPY dovecot/ /etc/dovecot/
COPY entrypoint.sh /entrypoint.sh
COPY bump-uidvalidity.sh /bump-uidvalidity.sh
RUN chmod +x /entrypoint.sh /bump-uidvalidity.sh \
    && chmod 644 /etc/dovecot/users \
    && chmod 644 /etc/dovecot/dovecot-*.conf

EXPOSE 1143 1993 2143
STOPSIGNAL SIGTERM
ENTRYPOINT ["/entrypoint.sh"]
