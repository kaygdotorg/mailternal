#!/bin/sh
# Bump UIDVALIDITY for a Maildir folder. Used from chaos.sh (container, mail stopped).
set -eu
mailbox="${1:-INBOX}"
case "$mailbox" in
  INBOX|inbox) path=/var/mail/qa/Maildir ;;
  *) path="/var/mail/qa/Maildir/.${mailbox}" ;;
esac
if [ ! -d "$path" ]; then
  echo "missing mailbox dir $path" >&2
  exit 1
fi
uidlist="$path/dovecot-uidlist"
new_v=$(date +%s)
if [ -f "$uidlist" ]; then
  first=$(head -n 1 "$uidlist")
  old=$(printf '%s\n' "$first" | sed -n 's/.*V\([0-9][0-9]*\).*/\1/p')
  if [ -n "${old:-}" ]; then
    new_v=$((old + 1))
    first_new=$(printf '%s\n' "$first" | awk -v n="$new_v" '{
      for (i = 1; i <= NF; i++) if ($i ~ /^V[0-9]+$/) $i = "V" n
      print
    }')
  else
    first_new="$first V$new_v"
  fi
  {
    printf '%s\n' "$first_new"
    tail -n +2 "$uidlist"
  } > "$uidlist.new"
  mv "$uidlist.new" "$uidlist"
  echo "uidlist: $first_new"
else
  printf '3 V%s N1\n' "$new_v" > "$uidlist"
  echo "created uidlist V$new_v"
fi
found=0
for f in "$path"/dovecot-uidvalidity*; do
  [ -e "$f" ] || continue
  found=1
  echo "old $(basename "$f"): $(cat "$f" 2>/dev/null || true)"
  printf '%s\n' "$new_v" > "$f"
done
if [ "$found" -eq 0 ]; then
  printf '%s\n' "$new_v" > "$path/dovecot-uidvalidity"
  echo "created dovecot-uidvalidity $new_v"
fi
for f in "$path"/dovecot.index* "$path"/dovecot.list.index*; do
  [ -e "$f" ] || continue
  rm -f "$f"
  echo "removed $(basename "$f")"
done
chown -R vmail:vmail /var/mail/qa 2>/dev/null || chown -R 5000:5000 /var/mail/qa
echo "UIDVALIDITY now $new_v path=$path"
