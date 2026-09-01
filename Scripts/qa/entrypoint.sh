#!/bin/sh
set -eu

MODE="${DOVECOT_MODE:-full}"
case "$MODE" in
  full|crippled) ;;
  *)
    echo "unknown DOVECOT_MODE=$MODE (expected full or crippled)" >&2
    exit 2
    ;;
esac

install -d -o vmail -g vmail /var/mail/qa/Maildir/cur \
  /var/mail/qa/Maildir/new \
  /var/mail/qa/Maildir/tmp

for box in Archive Sent Junk Drafts Trash Horrors; do
  install -d -o vmail -g vmail \
    "/var/mail/qa/Maildir/.${box}/cur" \
    "/var/mail/qa/Maildir/.${box}/new" \
    "/var/mail/qa/Maildir/.${box}/tmp"
done

install -d /etc/dovecot/certs /run/dovecot
rm -f /run/dovecot/master.pid

# Shared cert volume: first starter wins, others wait on the lock.
(
  flock 9
  if [ ! -s /etc/dovecot/certs/dovecot.crt ] || [ ! -s /etc/dovecot/certs/dovecot.key ]; then
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -keyout /etc/dovecot/certs/dovecot.key \
      -out /etc/dovecot/certs/dovecot.crt \
      -subj "/CN=mailternal.test" \
      -addext "subjectAltName=DNS:mailternal.test,DNS:imap.mailternal.test,DNS:localhost,DNS:mbp.local,IP:127.0.0.1,IP:::1"
    echo "generated self-signed cert -> /etc/dovecot/certs/dovecot.crt"
  fi
  chmod 644 /etc/dovecot/certs/dovecot.crt
  chmod 600 /etc/dovecot/certs/dovecot.key
) 9>/etc/dovecot/certs/.lock

chown -R vmail:vmail /var/mail/qa

conf="/etc/dovecot/dovecot-${MODE}.conf"
if ! doveconf -c "$conf" >/tmp/doveconf.out 2>/tmp/doveconf.err; then
  echo "doveconf failed:" >&2
  cat /tmp/doveconf.err >&2
  exit 1
fi
echo "starting dovecot mode=${MODE} conf=$conf"
exec dovecot -F -c "$conf"
