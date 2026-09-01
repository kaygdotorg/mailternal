#!/usr/bin/env python3
"""Seed the Mailternal QA Dovecot mailbox over IMAP APPEND/MULTIAPPEND.

Resumable and idempotent: STATUS each folder and skip when the EXISTS count
already meets the target. Designed for CPython 3.9+ with only the stdlib.
"""
from __future__ import annotations

import argparse
import os
import socket
import ssl
import sys
import time
from datetime import datetime, timedelta, timezone
from email.header import Header
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple

USER = "qa@mailternal.test"
PASSWORD = "qa-password"
DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 1143

TARGETS = {
    "INBOX": 100000,
    "Archive": 20000,
    "Sent": 500,
    "Junk": 300,
    "Drafts": 100,
}

MONTHS = (
    "Jan", "Feb", "Mar", "Apr", "May", "Jun",
    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
)

SENDERS = [
    ("Alice Example", "alice@example.com"),
    ("Bob Support", "bob@support.example.net"),
    ("田中太郎", "tanaka@example.jp"),
    ("Hans Müller", "hans@example.de"),
    ("فاطمة أحمد", "fatima@example.ae"),
    ("Сергей Петров", "sergey@example.ru"),
    ("李小龙", "li@example.cn"),
    ("Zoë O'Níall", "zoe@example.ie"),
    ("José García", "jose@example.es"),
    ("Νίκος Παπαδόπουλος", "nikos@example.gr"),
]

# 1x1 PNG
PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01"
    b"\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\nIDATx\x9cc\x00\x01"
    b"\x00\x00\x05\x00\x01\r\n-\xb4\x00\x00\x00\x00IEND\xaeB`\x82"
)
PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAE"
    "hQGAhKmMIQAAAABJRU5ErkJggg=="
)
FILLER = (b"lorem ipsum dolor sit amet, consectetur adipiscing elit. " * 20)

# 2016-08-31 .. 2026-08-31 UTC
DATE_START = datetime(2016, 8, 31, 0, 0, 0, tzinfo=timezone.utc)
DATE_SPAN = int(timedelta(days=3652).total_seconds())


def rfc2047_phrase(name: str) -> str:
    try:
        name.encode("ascii")
        if any(ch in name for ch in ('"', "\\")):
            return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'
        return name
    except UnicodeEncodeError:
        return Header(name, "utf-8").encode()


def imap_date(dt: datetime) -> str:
    day = "%2d" % dt.day
    return "%s-%s-%04d %02d:%02d:%02d +0000" % (
        day, MONTHS[dt.month - 1], dt.year, dt.hour, dt.minute, dt.second,
    )


def rfc822_date(dt: datetime) -> str:
    wdays = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
    return "%s, %02d %s %04d %02d:%02d:%02d +0000" % (
        wdays[dt.weekday()], dt.day, MONTHS[dt.month - 1], dt.year,
        dt.hour, dt.minute, dt.second,
    )


def date_for(index: int) -> datetime:
    off = (index * 9973 + 17) % DATE_SPAN
    return DATE_START + timedelta(seconds=off)


def target_size(index: int) -> int:
    r = (index * 1103515245 + 12345) & 0x7FFFFFFF
    bucket = r % 100
    if bucket < 70:
        return 1024 + (r % 3072)
    if bucket < 90:
        return 4096 + (r % 11264)
    if bucket < 99:
        return 15360 + (r % 15360)
    return 30720 + (r % 20480)


def pad_body(base: bytes, want: int) -> bytes:
    if len(base) >= want:
        return base
    need = want - len(base)
    q, r = divmod(need, len(FILLER))
    return base + FILLER * q + FILLER[:r]


def quote_mailbox(name: str) -> str:
    if name.upper() == "INBOX":
        return "INBOX"
    if all(ch.isalnum() or ch in ".-_" for ch in name):
        return name
    return '"' + name.replace("\\", "\\\\").replace('"', '\\"') + '"'


class ImapError(RuntimeError):
    pass


class ImapClient:
    def __init__(self, sock: socket.socket) -> None:
        self.sock = sock
        try:
            self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        except OSError:
            pass
        self.sock.settimeout(600)
        self.buf = bytearray()
        self.n = 0
        self.caps: List[str] = []
        self.greeting = self._readline()

    def wrap_tls(self, ctx: ssl.SSLContext, server_hostname: str) -> None:
        self.sock = ctx.wrap_socket(self.sock, server_hostname=server_hostname)
        self.buf.clear()

    def _recv_more(self) -> None:
        chunk = self.sock.recv(256 * 1024)
        if not chunk:
            raise ImapError("connection closed")
        self.buf.extend(chunk)

    def _readline(self) -> str:
        while True:
            idx = self.buf.find(b"\n")
            if idx >= 0:
                line = bytes(self.buf[:idx])
                del self.buf[: idx + 1]
                if line.endswith(b"\r"):
                    line = line[:-1]
                return line.decode("utf-8", "replace")
            self._recv_more()

    def send_raw(self, data: bytes) -> None:
        self.sock.sendall(data)

    def send_line(self, line: str) -> None:
        self.send_raw(line.encode("utf-8") + b"\r\n")

    def _read_until_tag(self, tag: str) -> Tuple[str, List[str]]:
        untagged: List[str] = []
        while True:
            line = self._readline()
            if line.startswith("+"):
                continue
            if line.startswith("*"):
                untagged.append(line)
                # Rare: untagged literal. Consume if present.
                if line.endswith("}") and "{" in line:
                    try:
                        n = int(line[line.rfind("{") + 1 : -1].rstrip("+"))
                    except ValueError:
                        n = 0
                    if n > 0:
                        have = 0
                        while have < n:
                            if self.buf:
                                take = min(n - have, len(self.buf))
                                del self.buf[:take]
                                have += take
                            else:
                                self._recv_more()
                        self._readline()
                continue
            parts = line.split(" ", 2)
            if parts and parts[0] == tag:
                status = parts[1] if len(parts) > 1 else ""
                if status not in ("OK", "NO", "BAD"):
                    raise ImapError("unexpected tagged response: " + line)
                return line, untagged
            untagged.append(line)

    def cmd(self, payload: str, ok: bool = True) -> Tuple[str, List[str]]:
        self.n += 1
        tag = "A%05d" % self.n
        self.send_line("%s %s" % (tag, payload))
        tagged, untagged = self._read_until_tag(tag)
        if ok and not tagged.startswith(tag + " OK"):
            raise ImapError(tagged)
        return tagged, untagged

    def login(self, user: str, password: str) -> None:
        def q(s: str) -> str:
            return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'

        tagged, untagged = self.cmd("LOGIN %s %s" % (q(user), q(password)))
        self._note_caps(untagged)
        tagged2, untagged2 = self.cmd("CAPABILITY")
        self._note_caps(untagged2 + untagged + [tagged, tagged2])

    def _note_caps(self, lines: Sequence[str]) -> None:
        found: List[str] = []
        for line in lines:
            up = line.upper()
            if "CAPABILITY COMPLETED" in up:
                continue
            if line.startswith("*") and " CAPABILITY " in (" " + up + " "):
                toks = line.split()
                start = 0
                for i, t in enumerate(toks):
                    if t.upper() == "CAPABILITY":
                        start = i + 1
                        break
                found = toks[start:]
            elif "[CAPABILITY" in up:
                lb = up.find("[CAPABILITY")
                rb = line.find("]", lb)
                if rb > lb:
                    inner = line[lb + 1:rb]
                    found = inner.split()[1:]
        if found:
            self.caps = found

    def has_cap(self, name: str) -> bool:
        return name.upper() in {c.upper() for c in self.caps}

    def create(self, mailbox: str) -> None:
        tagged, _ = self.cmd("CREATE " + quote_mailbox(mailbox), ok=False)
        if " OK" in tagged or "[ALREADYEXISTS]" in tagged.upper() or "already" in tagged.lower():
            return
        if tagged.split(" ", 2)[1] == "NO":
            return
        raise ImapError(tagged)

    def status_messages(self, mailbox: str) -> int:
        tagged, untagged = self.cmd(
            "STATUS %s (MESSAGES UIDNEXT UIDVALIDITY)" % quote_mailbox(mailbox)
        )
        for line in untagged:
            up = line.upper()
            if "MESSAGES" in up:
                toks = line.replace("(", " ").replace(")", " ").split()
                for i, t in enumerate(toks):
                    if t.upper() == "MESSAGES" and i + 1 < len(toks):
                        return int(toks[i + 1])
        raise ImapError("no MESSAGES in STATUS: %s %s" % (tagged, untagged))

    def select(self, mailbox: str) -> int:
        tagged, untagged = self.cmd("SELECT " + quote_mailbox(mailbox))
        exists = None
        for line in untagged:
            parts = line.split()
            if len(parts) >= 3 and parts[0] == "*" and parts[2].upper() == "EXISTS":
                exists = int(parts[1])
        if exists is None:
            raise ImapError("no EXISTS in SELECT: %s %s" % (tagged, untagged))
        return exists

    def multiappend(self, mailbox: str, items: Sequence[Tuple[bytes, str, str]]) -> str:
        """items: (rfc822, flags_atom_or_empty, imap_date_without_quotes)."""
        if not items:
            return ""
        self.n += 1
        tag = "A%05d" % self.n
        chunks: List[bytes] = [("%s APPEND %s" % (tag, quote_mailbox(mailbox))).encode("ascii")]
        for body, flags, dt in items:
            if not body.endswith(b"\r\n"):
                body = body + b"\r\n"
            piece = b""
            if flags:
                piece += b" (" + flags.encode("ascii") + b")"
            piece += b' "' + dt.encode("ascii") + b'"'
            piece += b" {" + str(len(body)).encode("ascii") + b"+}\r\n"
            chunks.append(piece)
            chunks.append(body)
        chunks.append(b"\r\n")
        self.send_raw(b"".join(chunks))
        tagged, _ = self._read_until_tag(tag)
        if not tagged.startswith(tag + " OK"):
            raise ImapError(tagged)
        return tagged

    def append_one(self, mailbox: str, body: bytes, flags: str, dt: str) -> str:
        return self.multiappend(mailbox, [(body, flags, dt)])

    def logout(self) -> None:
        try:
            self.cmd("LOGOUT", ok=False)
        except Exception:
            pass
        try:
            self.sock.close()
        except Exception:
            pass


def tls_context() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    return ctx


def connect(host: str, port: int, mode: str, timeout: float = 60.0) -> ImapClient:
    raw = socket.create_connection((host, port), timeout=timeout)
    ctx = tls_context()
    if mode == "imaps":
        wrapped = ctx.wrap_socket(raw, server_hostname=host)
        client = ImapClient(wrapped)
        return client
    client = ImapClient(raw)
    if mode == "starttls":
        client.cmd("STARTTLS")
        client.wrap_tls(ctx, host)
    return client


def wait_ready(host: str, port: int, mode: str, timeout: float = 60.0) -> None:
    deadline = time.time() + timeout
    last = None
    while time.time() < deadline:
        try:
            c = connect(host, port, mode, timeout=5.0)
            greet = c.greeting
            c.sock.close()
            if "OK" in greet:
                return
            last = greet
        except Exception as exc:
            last = exc
            time.sleep(0.4)
    raise ImapError("server not ready on %s:%s (%s)" % (host, port, last))


def find_corpus() -> Optional[Path]:
    env = os.environ.get("MAILTERNAL_CORPUS")
    here = Path(__file__).resolve().parent
    candidates = []
    if env:
        candidates.append(Path(env))
    candidates.extend(
        [
            here / "corpus",
            here.parents[1] / "Tests" / "MailternalMIMETests" / "Corpus",
            Path.cwd() / "Tests" / "MailternalMIMETests" / "Corpus",
        ]
    )
    for c in candidates:
        try:
            if c.is_dir() and any(c.glob("*.eml")):
                return c
        except OSError:
            continue
    return None


def fallback_horrors() -> List[Tuple[str, bytes]]:
    """30 malformed messages covering the MIME corpus categories."""
    msgs: List[Tuple[str, bytes]] = []

    def add(name: str, text: str) -> None:
        raw = text.replace("\n", "\r\n").encode("utf-8", "surrogateescape")
        msgs.append((name, raw))

    add(
        "malformed-boundary",
        "From: a@b.com\nSubject: No boundary\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: multipart/mixed\n\nthis is not a valid multipart\n",
    )
    add(
        "missing-terminal-boundary",
        "From: a@b.com\nSubject: no closer\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=aaa\n\n--aaa\n"
        "Content-Type: text/plain\n\nbody only, never closed\n",
    )
    add(
        "extra-whitespace-boundary",
        "From: a@b.com\nSubject: ws boundary\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=\"zz\"\n\n--zz \n"
        "Content-Type: text/plain\n\nhi\n--zz--\n",
    )
    add(
        "broken-qp",
        "From: a@b.com\nSubject: broken qp\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\n"
        "=ZZHel=\nlo=41= \nWorld\n",
    )
    add(
        "broken-base64",
        "From: a@b.com\nSubject: broken b64\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: base64\n\n"
        "SGVsbG8g@@V29ybGQ=\n",
    )
    add(
        "windows-1252-as-latin1",
        "From: a@b.com\nSubject: smart quotes\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain; charset=iso-8859-1\n\n",
    )
    msgs[-1] = (
        "windows-1252-as-latin1",
        msgs[-1][1] + b"He said \x93hello\x94 \x96 really.\r\n",
    )
    add(
        "shift-jis-as-utf8",
        "From: a@b.com\nSubject: sjis\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain; charset=utf-8\n\n",
    )
    msgs[-1] = (
        "shift-jis-as-utf8",
        msgs[-1][1] + b"\x82\xb1\x82\xf1\x82\xc9\x82\xbf\x82\xcd\r\n",
    )
    msgs.append(
        (
            "eight-bit-headers",
            b"From: \xc4\xe9\xf1 Sender <a@b.com>\r\n"
            b"Subject: caf\xe9 au lait\r\n"
            b"Date: Wed, 01 Jan 2020 00:00:00 +0000\r\n"
            b"Content-Type: text/plain; charset=iso-8859-1\r\n\r\n"
            b"body\r\n",
        )
    )
    nest = ["From: a@b.com", "Date: Wed, 01 Jan 2020 00:00:00 +0000", "Subject: nest",
            "MIME-Version: 1.0", 'Content-Type: multipart/mixed; boundary="B1"', ""]
    for i in range(1, 11):
        if i > 1:
            nest.append("--B%d" % (i - 1))
            nest.append('Content-Type: multipart/mixed; boundary="B%d"' % i)
            nest.append("")
        else:
            nest.append("--B1")
            nest.append('Content-Type: multipart/mixed; boundary="B2"')
            nest.append("")
    # rebuild deep nesting like the corpus
    lines = [
        "From: a@b.com",
        "Date: Wed, 01 Jan 2020 00:00:00 +0000",
        "Subject: nest",
        "MIME-Version: 1.0",
        'Content-Type: multipart/mixed; boundary="B1"',
        "",
    ]
    for i in range(1, 11):
        lines.append("--B%d" % i)
        if i < 10:
            lines.append('Content-Type: multipart/mixed; boundary="B%d"' % (i + 1))
            lines.append("")
        else:
            lines.append("Content-Type: text/plain; charset=utf-8")
            lines.append("")
            lines.append("leaf")
    for i in range(10, 0, -1):
        lines.append("--B%d--" % i)
    add("deep-nesting", "\n".join(lines) + "\n")
    add(
        "missing-date",
        "From: a@b.com\nSubject: undated\nContent-Type: text/plain; charset=utf-8\n\nno date here\n",
    )
    add(
        "truncated-multipart",
        "From: a@b.com\nSubject: trunc\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=xx\n\n--xx\n"
        "Content-Type: text/plain\nContent-Transfer-Encoding: base64\n\nSGVsb",
    )
    add(
        "duplicate-content-type",
        "From: a@b.com\nSubject: dup ct\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain; charset=utf-8\nContent-Type: text/html; charset=utf-8\n\n"
        "<b>which</b>\n",
    )
    add(
        "utf8-labelled-latin1-bytes",
        "From: a@b.com\nSubject: mislabeled\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain; charset=utf-8\n\n",
    )
    msgs[-1] = ("utf8-labelled-latin1-bytes", msgs[-1][1] + b"na\xefve caf\xe9\r\n")
    add(
        "overlong-rfc2047",
        "From: a@b.com\nSubject: %s\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain\n\nx\n" % Header("あ" * 200, "utf-8").encode(),
    )
    add(
        "nested-rfc822-malformed",
        "From: a@b.com\nSubject: inner\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: message/rfc822\n\n"
        "this is not a message\nNo headers even\n",
    )
    msgs.append(
        (
            "binary-with-nuls",
            b"From: a@b.com\r\nSubject: nuls\r\nDate: Wed, 01 Jan 2020 00:00:00 +0000\r\n"
            b"Content-Type: application/octet-stream\r\nContent-Transfer-Encoding: binary\r\n\r\n"
            b"pre\x00mid\x00post\r\n",
        )
    )
    add(
        "space-before-colon",
        "From : a@b.com\nSubject : spaced\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n\nbody\n",
    )
    msgs.append(
        (
            "bare-lf",
            b"From: a@b.com\nSubject: bare lf\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n\nbare lf body\n",
        )
    )
    add(
        "invalid-preamble-epilogue",
        "From: a@b.com\nSubject: pre\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=zz\n\n"
        "preamble with \x80 bytes\n--zz\nContent-Type: text/plain\n\nhi\n--zz--\n"
        "epilogue leftover\n",
    )
    add(
        "boundary-in-body",
        "From: a@b.com\nSubject: fake dash\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=uniq\n\n--uniq\n"
        "Content-Type: text/plain\n\n--uniq is mentioned in body but not a delimiter\n--uniq--\n",
    )
    add(
        "unknown-cte",
        "From: a@b.com\nSubject: x-uu\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain\nContent-Transfer-Encoding: x-unknown-4\n\n"
        "begin 644 x\n+2&5L;&\\`\n`\nend\n",
    )
    add(
        "empty-multipart",
        "From: a@b.com\nSubject: empty\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: multipart/alternative; boundary=e\n\n--e--\n",
    )
    add(
        "huge-header",
        "From: a@b.com\nSubject: %s\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "X-Long: %s\n\nbody\n" % ("A" * 5000, "B" * 8000),
    )
    add(
        "missing-from",
        "Subject: no from\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n\nnobody\n",
    )
    add(
        "unparsable-date",
        "From: a@b.com\nSubject: when\nDate: next Tuesday after never\n\nbody\n",
    )
    add(
        "mixed-related-alternative",
        "From: a@b.com\nSubject: mix\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=m\n\n--m\n"
        "Content-Type: multipart/related; boundary=r\n\n--r\n"
        "Content-Type: multipart/alternative; boundary=a\n\n--a\n"
        "Content-Type: text/plain\n\nplain\n--a\nContent-Type: text/html\n\n"
        "<p>html</p>\n--a--\n--r\nContent-Type: image/png; name=x.png\n"
        "Content-ID: <x@x>\nContent-Transfer-Encoding: base64\n\n%s\n--r--\n--m--\n" % PNG_B64,
    )
    add(
        "rfc2231-broken",
        "From: a@b.com\nSubject: 2231\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain;\n name*0=\"utf-8''this%%20is%%20\";\n name*1=broken%\n\n"
        "filename chaos\n",
    )
    add(
        "address-groups",
        "From: a@b.com\nTo: Undisclosed recipients:;\nCc: Friends: zoe@e.com, hans@e.de;\n"
        "Subject: groups\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n\nhi\n",
    )
    add(
        "message-ids-angle",
        "From: a@b.com\nSubject: ids\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Message-ID: not-an-angle-id@host\nIn-Reply-To: <one@host> two@host\n"
        "References: <a@b> c@d <e@f>\n\nbody\n",
    )
    add(
        "format-flowed-broken",
        "From: a@b.com\nSubject: flowed\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain; charset=utf-8; format=flowed\n\n"
        "This line is flowed \nbut the next is not quoted properly>> stuff\n",
    )
    add(
        "header-fold-mid-word",
        "From: a@b.com\nSubject: hel\n lo\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n\nbody\n",
    )
    add(
        "content-disposition-unquoted",
        "From: a@b.com\nSubject: disp\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain\nContent-Disposition: attachment; filename=foo bar.txt\n\n"
        "x\n",
    )
    add(
        "charset-unknown",
        "From: a@b.com\nSubject: cs\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "Content-Type: text/plain; charset=x-totally-bogus\n\n??\n",
    )
    add(
        "html-unclosed-cid",
        "From: a@b.com\nSubject: cid\nDate: Wed, 01 Jan 2020 00:00:00 +0000\n"
        "MIME-Version: 1.0\nContent-Type: text/html; charset=utf-8\n\n"
        '<img src="cid:missing@part"> no related container\n',
    )
    while len(msgs) < 30:
        n = len(msgs) + 1
        add(
            "extra-malformed-%d" % n,
            "From: a@b.com\nSubject: extra %d\nDate: not-a-date-%d\n"
            "Content-Type: multipart/mixed; boundary=\n\nnope %d\n" % (n, n, n),
        )
    return msgs[:30]


def load_horrors() -> List[Tuple[str, bytes]]:
    corpus = find_corpus()
    if corpus is None:
        print("corpus dir missing; generating 30 fallback malformed messages")
        return fallback_horrors()
    out: List[Tuple[str, bytes]] = []
    for path in sorted(corpus.glob("*.eml")):
        out.append((path.name, path.read_bytes()))
    print("corpus: %s (%d messages)" % (corpus, len(out)))
    return out


def thread_meta(index: int) -> Tuple[str, Optional[str], Optional[str]]:
    """Return (msgid, in_reply_to, references). Threads of length 2-12."""
    # Stable thread id: groups of 2-12 based on a wave.
    wave = 2 + (index // 500) % 11
    thread_start = (index // wave) * wave
    msgid = "<qa.%d.%d@mailternal.test>" % (thread_start, index)
    if index == thread_start:
        return msgid, None, None
    parent_i = index - 1
    parent = "<qa.%d.%d@mailternal.test>" % (thread_start, parent_i)
    refs = []
    for j in range(thread_start, index):
        refs.append("<qa.%d.%d@mailternal.test>" % (thread_start, j))
        if len(refs) > 8:
            refs = refs[:1] + refs[-7:]
    return msgid, parent, " ".join(refs)


def build_plain(index: int, folder: str, size: int, dt: datetime) -> bytes:
    sender_name, sender_addr = SENDERS[index % len(SENDERS)]
    msgid, irt, refs = thread_meta(index)
    subj_core = "[%s] thread %d msg %d" % (folder, index // 10, index)
    if index % 17 == 0:
        subj = Header("返信: " + subj_core, "utf-8").encode()
    elif index % 19 == 0:
        subj = Header("Ответ: " + subj_core, "utf-8").encode()
    else:
        subj = subj_core
    headers = [
        "From: %s <%s>" % (rfc2047_phrase(sender_name), sender_addr),
        "To: %s" % USER,
        "Subject: %s" % subj,
        "Date: %s" % rfc822_date(dt),
        "Message-ID: %s" % msgid,
        "MIME-Version: 1.0",
        "X-QA-Index: %d" % index,
        "X-QA-Folder: %s" % folder,
    ]
    if irt:
        headers.append("In-Reply-To: %s" % irt)
    if refs:
        headers.append("References: %s" % refs)
    if folder == "Drafts":
        headers.append("X-Draft: yes")

    html = index % 7 == 0
    if html:
        boundary = "qa-%d-%d" % (index, size)
        rel = boundary + "-rel"
        alt = boundary + "-alt"
        cid = "logo.%d@mailternal.test" % index
        inner = (
            "Content-Type: multipart/related; boundary=\"%s\"\r\n\r\n"
            "--%s\r\n"
            "Content-Type: multipart/alternative; boundary=\"%s\"\r\n\r\n"
            "--%s\r\n"
            "Content-Type: text/plain; charset=utf-8\r\n"
            "Content-Transfer-Encoding: 8bit\r\n\r\n"
            "QA message %d in %s.\r\n\r\n"
            "--%s\r\n"
            "Content-Type: text/html; charset=utf-8\r\n"
            "Content-Transfer-Encoding: 8bit\r\n\r\n"
            "<html><body><p>QA message %d in %s.</p>"
            "<img src=\"cid:%s\" alt=\"logo\"></body></html>\r\n"
            "--%s--\r\n"
            "--%s\r\n"
            "Content-Type: image/png; name=\"logo.png\"\r\n"
            "Content-Transfer-Encoding: base64\r\n"
            "Content-ID: <%s>\r\n"
            "Content-Disposition: inline; filename=\"logo.png\"\r\n\r\n"
            "%s\r\n"
            "--%s--\r\n" % (
                rel, rel, alt, alt, index, folder, alt, index, folder, cid, alt,
                rel, cid, PNG_B64, rel,
            )
        ).encode("utf-8")
        headers.append('Content-Type: multipart/mixed; boundary="%s"' % boundary)
        base = (
            "\r\n".join(headers).encode("utf-8")
            + b"\r\n\r\n--"
            + boundary.encode("ascii")
            + b"\r\n"
            + inner
            + b"--"
            + boundary.encode("ascii")
            + b"--\r\n"
        )
        # padding as extra text part would break the closer; pad inside by repeating PNG lines is messy.
        # Pad by adding a trailing text part before the closer: rebuild if needed.
        if len(base) < size:
            extra = pad_body(b"PAD\r\n", size - len(base) + 80)
            base = (
                "\r\n".join(headers).encode("utf-8")
                + b"\r\n\r\n--"
                + boundary.encode("ascii")
                + b"\r\n"
                + inner
                + b"--"
                + boundary.encode("ascii")
                + b"\r\nContent-Type: text/plain; charset=us-ascii\r\n\r\n"
                + extra
                + b"\r\n--"
                + boundary.encode("ascii")
                + b"--\r\n"
            )
        return base

    headers.append("Content-Type: text/plain; charset=utf-8")
    headers.append("Content-Transfer-Encoding: 8bit")
    head = "\r\n".join(headers).encode("utf-8") + b"\r\n\r\n"
    body = ("QA message %d in %s.\r\n" % (index, folder)).encode("utf-8")
    return pad_body(head + body, size)


def flags_for(index: int, folder: str) -> str:
    bits = []
    if folder == "Drafts":
        bits.append("\\Draft")
    if folder == "Junk" or index % 23 == 0:
        bits.append("\\Seen")
    if index % 41 == 0:
        bits.append("\\Flagged")
    if index % 53 == 0:
        bits.append("\\Answered")
    return " ".join(bits)


def gen_message(index: int, folder: str) -> Tuple[bytes, str, str]:
    dt = date_for(index)
    body = build_plain(index, folder, target_size(index), dt)
    return body, flags_for(index, folder), imap_date(dt)


def fmt_eta(seconds: float) -> str:
    if seconds < 0 or seconds > 86400 * 10:
        return "?"
    s = int(seconds)
    return "%d:%02d:%02d" % (s // 3600, (s % 3600) // 60, s % 60)


def seed_folder(
    client: ImapClient,
    folder: str,
    target: int,
    factory: Callable[[int], Tuple[bytes, str, str]],
    start_index: int = 0,
    batch_msgs: int = 40,
    batch_bytes: int = 512 * 1024,
) -> int:
    client.create(folder)
    current = client.status_messages(folder)
    if current >= target:
        print("%s: %d >= %d — skip" % (folder, current, target))
        return current
    print("%s: %d -> %d" % (folder, current, target))
    t0 = time.time()
    done0 = current
    use_multi = client.has_cap("MULTIAPPEND")
    while current < target:
        batch: List[Tuple[bytes, str, str]] = []
        nbytes = 0
        while current + len(batch) < target and len(batch) < batch_msgs and nbytes < batch_bytes:
            idx = start_index + current + len(batch)
            item = factory(idx)
            batch.append(item)
            nbytes += len(item[0])
        try:
            if use_multi:
                client.multiappend(folder, batch)
            else:
                for item in batch:
                    client.append_one(folder, item[0], item[1], item[2])
        except ImapError as exc:
            print("  APPEND failed (%s); retrying one-by-one" % exc)
            for item in batch:
                client.append_one(folder, item[0], item[1], item[2])
        current += len(batch)
        elapsed = max(time.time() - t0, 0.001)
        rate = (current - done0) / elapsed
        remain = (target - current) / rate if rate > 0 else 0
        print(
            "  %s %d/%d (%.1f%%)  %.0f msg/s  %d bytes this batch  ETA %s"
            % (
                folder,
                current,
                target,
                100.0 * current / target,
                rate,
                nbytes,
                fmt_eta(remain),
            ),
            flush=True,
        )
    return current


def extra_append(
    client: ImapClient, folder: str, count: int, origin: int
) -> None:
    client.create(folder)
    base = client.status_messages(folder)

    def factory(i: int) -> Tuple[bytes, str, str]:
        return gen_message(10_000_000 + origin + i, folder)

    seed_folder(client, folder, base + count, factory, start_index=0)


def print_status(client: ImapClient, folders: Sequence[str]) -> None:
    print("capabilities:", " ".join(client.caps))
    for folder in folders:
        try:
            n = client.status_messages(folder)
            print("STATUS %s MESSAGES %d" % (folder, n))
        except ImapError as exc:
            print("STATUS %s FAILED %s" % (folder, exc))


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default=os.environ.get("QA_IMAP_HOST", DEFAULT_HOST))
    p.add_argument("--port", type=int, default=int(os.environ.get("QA_IMAP_PORT", DEFAULT_PORT)))
    p.add_argument(
        "--tls",
        choices=("starttls", "imaps", "plain"),
        default=os.environ.get("QA_IMAP_TLS", "starttls"),
    )
    p.add_argument("--user", default=USER)
    p.add_argument("--password", default=PASSWORD)
    p.add_argument("--status", action="store_true", help="print STATUS/CAPABILITY and exit")
    p.add_argument(
        "--verify",
        action="store_true",
        help="SELECT INBOX and print EXISTS; also dump CAPABILITY",
    )
    p.add_argument(
        "--extra",
        nargs=2,
        metavar=("FOLDER", "N"),
        help="append N extra messages to FOLDER (ignore targets)",
    )
    p.add_argument("--inbox", type=int, default=TARGETS["INBOX"])
    p.add_argument("--archive", type=int, default=TARGETS["Archive"])
    p.add_argument("--wait", type=float, default=60.0, help="seconds to wait for banner")
    p.add_argument("--batch", type=int, default=40)
    return p.parse_args(argv)


def main(argv: Optional[Sequence[str]] = None) -> int:
    args = parse_args(argv)
    wait_ready(args.host, args.port, args.tls, timeout=args.wait)
    client = connect(args.host, args.port, args.tls)
    print("greeting:", client.greeting)
    client.login(args.user, args.password)
    print("login caps:", " ".join(client.caps))
    print("MULTIAPPEND:" , "yes" if client.has_cap("MULTIAPPEND") else "no")
    print("LITERAL+:", "yes" if client.has_cap("LITERAL+") else "no")

    folders = ["INBOX", "Archive", "Sent", "Junk", "Drafts", "Horrors", "Trash"]
    for f in folders:
        client.create(f)

    if args.status:
        print_status(client, folders)
        client.logout()
        return 0

    if args.verify:
        exists = client.select("INBOX")
        print("SELECT INBOX EXISTS %d" % exists)
        print_status(client, folders)
        client.logout()
        return 0 if exists >= args.inbox else 1

    if args.extra:
        folder, n_s = args.extra
        extra_append(client, folder, int(n_s), origin=int(time.time()))
        print_status(client, [folder])
        client.logout()
        return 0

    t0 = time.time()
    horrors = load_horrors()

    def horror_factory(i: int) -> Tuple[bytes, str, str]:
        name, raw = horrors[i % len(horrors)]
        dt = date_for(9_000_000 + i)
        return raw, "", imap_date(dt)

    attempts = 0
    while True:
        attempts += 1
        try:
            seed_folder(
                client, "INBOX", args.inbox,
                lambda i: gen_message(i, "INBOX"),
                batch_msgs=args.batch,
            )
            seed_folder(
                client, "Archive", args.archive,
                lambda i: gen_message(1_000_000 + i, "Archive"),
                batch_msgs=args.batch,
            )
            seed_folder(
                client, "Sent", TARGETS["Sent"],
                lambda i: gen_message(2_000_000 + i, "Sent"),
            )
            seed_folder(
                client, "Junk", TARGETS["Junk"],
                lambda i: gen_message(3_000_000 + i, "Junk"),
            )
            seed_folder(
                client, "Drafts", TARGETS["Drafts"],
                lambda i: gen_message(4_000_000 + i, "Drafts"),
            )
            seed_folder(client, "Horrors", len(horrors), horror_factory, batch_msgs=10)
            break
        except (ImapError, OSError, socket.timeout) as exc:
            if attempts >= 20:
                raise
            print("connection lost (%s); reconnecting in 2s (attempt %d)" % (exc, attempts), flush=True)
            try:
                client.logout()
            except Exception:
                pass
            time.sleep(2)
            wait_ready(args.host, args.port, args.tls, timeout=args.wait)
            client = connect(args.host, args.port, args.tls)
            client.login(args.user, args.password)
            for f in folders:
                client.create(f)

    print_status(client, folders)
    exists = client.select("INBOX")
    print("SELECT INBOX EXISTS %d" % exists)
    print("seed finished in %.1fs" % (time.time() - t0))
    client.logout()
    return 0 if exists >= args.inbox else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        sys.exit(130)
    except Exception as exc:
        print("error: %s" % exc, file=sys.stderr)
        sys.exit(1)
