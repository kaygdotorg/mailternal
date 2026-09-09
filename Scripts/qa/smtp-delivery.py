#!/usr/bin/env python3
"""Live SMTP/CLI delivery smoke test for a private Mailternal QA container.

This is intentionally a scenario, not a test framework.  Run it on agents@mbp
with a private QA app bundle and the QA Dovecot fixture, for example:

  python3 Scripts/qa/smtp-delivery.py \
      --app ~/Applications/Mailternal.app \
      --certificate ~/Developer/Worktrees/mailternal-qa/certs/dovecot.crt \
      --private-key ~/Developer/Worktrees/mailternal-qa/certs/dovecot.key

The harness owns a localhost SMTP fixture and a private Mailternal container.
It never uses Keychain credentials: QALaunch injects an in-memory credential
store and the CLI explicitly reuses the synthetic QA IMAP password for SMTP.
On success its temporary root is removed.  On failure it is retained and the
app/fixture logs remain available for diagnosis.
"""

from __future__ import annotations

import argparse
import base64
import contextlib
import hashlib
import imaplib
import json
import os
import pathlib
import plistlib
import select
import shlex
import shutil
import socket
import socketserver
import ssl
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from typing import Any, Callable, Iterable


QA_USER = "qa@mailternal.test"
QA_PASSWORD = "qa-password"
QA_ACCOUNT = "qa-127.0.0.1-1143"
IMAP_HOST = "127.0.0.1"
IMAP_PORT = 1143
IMAP_SECURITY = "startTLS"
CLI_SCHEMA = "mailternal.cli.result.v1"
MAX_CLI_SECONDS = 45.0
MAX_IMAP_SECONDS = 15.0
MAX_MIME_CAPTURE = 32 * 1024 * 1024


class HarnessFailure(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise HarnessFailure(message)


def pass_check(message: str) -> None:
    print(f"PASS {message}", flush=True)




def resolve_app(path: pathlib.Path) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
    """Return (CLI executable, app executable, argument passed as --app)."""
    supplied = path.expanduser().resolve()
    if supplied.is_dir():
        plist_path = supplied / "Contents" / "Info.plist"
        require(plist_path.is_file(), f"app bundle has no Info.plist: {supplied}")
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
        executable_name = plist.get("CFBundleExecutable")
        require(isinstance(executable_name, str) and executable_name, "Info.plist has no CFBundleExecutable")
        app_executable = supplied / "Contents" / "MacOS" / executable_name
        cli_executable = supplied / "Contents" / "MacOS" / "mailternal"
        require(app_executable.is_file(), f"app executable is missing: {app_executable}")
        require(cli_executable.is_file(), f"mailternal CLI is missing: {cli_executable}")
        return cli_executable, app_executable, supplied

    require(supplied.is_file(), f"--app is not a file or bundle: {supplied}")
    sibling_cli = supplied.parent / "mailternal"
    sibling_app = supplied.parent / "Mailternal"
    if supplied.name == "mailternal":
        require(sibling_app.is_file(), "a direct mailternal CLI path needs its sibling Mailternal app executable")
        return supplied, sibling_app, supplied
    require(sibling_cli.is_file(), f"mailternal CLI is missing beside app executable: {sibling_cli}")
    return sibling_cli, supplied, supplied

class SMTPFixture:
    """Small, bounded STARTTLS/AUTH SMTP server with controllable outcomes."""

    def __init__(self, root: pathlib.Path, certificate: pathlib.Path, private_key: pathlib.Path) -> None:
        self.root = root
        self.capture_root = root / "smtp-messages"
        self.capture_root.mkdir(mode=0o700)
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.context.minimum_version = ssl.TLSVersion.TLSv1_2
        self.context.load_cert_chain(str(certificate), str(private_key))
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(8)
        self.listener.settimeout(0.5)
        self.port = self.listener.getsockname()[1]
        self.stop_event = threading.Event()
        self.data_started = threading.Event()
        self.hold_release = threading.Event()
        self.thread = threading.Thread(target=self._accept_loop, name="mailternal-qa-smtp", daemon=True)
        self.connections: list[socket.socket] = []
        self.connections_lock = threading.Lock()
        self.mode_lock = threading.Lock()
        self.mode = "accept"
        self.count_lock = threading.Lock()
        self.completed = 0
        self.capture_paths: list[pathlib.Path] = []
        self.started = False

    def start(self) -> None:
        self.started = True
        self.thread.start()

    def set_mode(self, mode: str) -> None:
        require(mode in {"accept", "reject_rcpt", "close_after_data", "hold_data"}, f"unknown SMTP fixture mode: {mode}")
        with self.mode_lock:
            self.mode = mode
        if mode != "hold_data":
            self.hold_release.set()
        else:
            self.hold_release.clear()
            self.data_started.clear()

    def release_hold(self) -> None:
        self.hold_release.set()

    def completed_count(self) -> int:
        with self.count_lock:
            return self.completed

    def stop(self) -> None:
        if not self.started:
            return
        self.stop_event.set()
        self.hold_release.set()
        with contextlib.suppress(OSError):
            self.listener.close()
        with self.connections_lock:
            connections = list(self.connections)
        for connection in connections:
            with contextlib.suppress(OSError):
                connection.shutdown(socket.SHUT_RDWR)
            with contextlib.suppress(OSError):
                connection.close()
        self.thread.join(timeout=5)
        self.started = False

    def _current_mode(self) -> str:
        with self.mode_lock:
            return self.mode

    def _accept_loop(self) -> None:
        while not self.stop_event.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            connection.settimeout(10.0)
            with self.connections_lock:
                self.connections.append(connection)
            worker = threading.Thread(target=self._handle_client, args=(connection,), daemon=True)
            worker.start()

    def _handle_client(self, connection: socket.socket) -> None:
        tls_connection: socket.socket = connection
        try:
            self._send(tls_connection, b"220 localhost ESMTP mailternal-qa\r\n")
            secure = False
            authenticated = False
            while not self.stop_event.is_set():
                line = self._read_line(tls_connection)
                if line is None:
                    return
                command = line.decode("ascii", "replace")
                upper = command.upper()
                if upper.startswith("EHLO ") or upper.startswith("HELO "):
                    if secure:
                        self._send(tls_connection, b"250-localhost\r\n250-AUTH PLAIN LOGIN\r\n250-SIZE 52428800\r\n250 SMTPUTF8\r\n")
                    else:
                        self._send(tls_connection, b"250-localhost\r\n250-STARTTLS\r\n250 AUTH PLAIN LOGIN\r\n")
                elif upper == "STARTTLS":
                    if secure:
                        self._send(tls_connection, b"503 5.5.1 Already secure\r\n")
                        continue
                    self._send(tls_connection, b"220 2.0.0 Ready to start TLS\r\n")
                    tls_connection = self.context.wrap_socket(tls_connection, server_side=True)
                    tls_connection.settimeout(10.0)
                    secure = True
                elif upper.startswith("AUTH "):
                    if not secure:
                        self._send(tls_connection, b"530 5.7.0 Must issue STARTTLS first\r\n")
                    elif self._authenticate(tls_connection, command):
                        authenticated = True
                        self._send(tls_connection, b"235 2.7.0 Authentication successful\r\n")
                    else:
                        self._send(tls_connection, b"535 5.7.8 Authentication credentials invalid\r\n")
                elif not authenticated and (upper.startswith(("MAIL FROM:", "RCPT TO:")) or upper == "DATA"):
                    self._send(tls_connection, b"530 5.7.0 Authentication required\r\n")
                elif upper.startswith("MAIL FROM:"):
                    self._send(tls_connection, b"250 2.1.0 Sender OK\r\n")
                elif upper.startswith("RCPT TO:"):
                    if self._current_mode() == "reject_rcpt":
                        self._send(tls_connection, b"550 5.1.1 QA recipient rejected\r\n")
                    else:
                        self._send(tls_connection, b"250 2.1.5 Recipient OK\r\n")
                elif upper == "DATA":
                    self._send(tls_connection, b"354 End data with <CR><LF>.<CR><LF>\r\n")
                    self.data_started.set()
                    mode = self._current_mode()
                    if mode == "hold_data":
                        # Do not read: a large upload remains before the SMTP
                        # client's beforeCommit marker.  The scenario cancels,
                        # then releases this connection without accepting DATA.
                        self.hold_release.wait(timeout=120.0)
                        return
                    completed, capture = self._read_data(tls_connection)
                    if not completed:
                        return
                    message_path = self.capture_root / f"message-{self.completed_count() + 1:03d}.eml"
                    with message_path.open("wb") as handle:
                        handle.write(capture)
                    with self.count_lock:
                        self.completed += 1
                        self.capture_paths.append(message_path)
                    if mode == "close_after_data":
                        return
                    self._send(tls_connection, b"250 2.0.0 Message accepted\r\n")
                elif upper == "QUIT":
                    self._send(tls_connection, b"221 2.0.0 Bye\r\n")
                    return
                elif upper == "RSET":
                    self._send(tls_connection, b"250 2.0.0 Reset\r\n")
                else:
                    self._send(tls_connection, b"502 5.5.2 Command not implemented\r\n")
        except (OSError, ssl.SSLError, UnicodeError):
            return
        finally:
            with contextlib.suppress(OSError):
                tls_connection.close()
            with self.connections_lock:
                with contextlib.suppress(ValueError):
                    self.connections.remove(connection)

    @staticmethod
    def _send(connection: socket.socket, data: bytes) -> None:
        connection.sendall(data)

    @staticmethod
    def _read_line(connection: socket.socket) -> bytes | None:
        data = bytearray()
        while len(data) <= 16 * 1024:
            byte = connection.recv(1)
            if not byte:
                return None
            data.extend(byte)
            if data.endswith(b"\r\n"):
                return bytes(data[:-2])
        raise OSError("SMTP line exceeded bound")

    def _authenticate(self, connection: socket.socket, command: str) -> bool:
        fields = command.split()
        if len(fields) < 2:
            return False
        mechanism = fields[1].upper()
        if mechanism == "PLAIN":
            if len(fields) == 2:
                self._send(connection, b"334 \r\n")
                line = self._read_line(connection)
                if line is None:
                    return False
                encoded = line
            else:
                encoded = fields[2].encode("ascii", "ignore")
            with contextlib.suppress(ValueError):
                payload = base64.b64decode(encoded, validate=True)
                return payload == b"\x00" + QA_USER.encode() + b"\x00" + QA_PASSWORD.encode()
            return False
        if mechanism == "LOGIN":
            self._send(connection, b"334 VXNlcm5hbWU6\r\n")
            username = self._read_line(connection)
            if username is None:
                return False
            self._send(connection, b"334 UGFzc3dvcmQ6\r\n")
            password = self._read_line(connection)
            if password is None:
                return False
            with contextlib.suppress(ValueError):
                return (
                    base64.b64decode(username, validate=True) == QA_USER.encode()
                    and base64.b64decode(password, validate=True) == QA_PASSWORD.encode()
                )
            return False
        return False

    @staticmethod
    def _read_data(connection: socket.socket) -> tuple[bool, bytes]:
        pending = bytearray()
        message = bytearray()
        while True:
            chunk = connection.recv(64 * 1024)
            if not chunk:
                return False, bytes(message)
            pending.extend(chunk)
            while True:
                marker = pending.find(b"\r\n")
                if marker < 0:
                    if len(pending) > 1 * 1024 * 1024:
                        raise OSError("SMTP DATA line exceeded bound")
                    break
                line = bytes(pending[:marker])
                del pending[: marker + 2]
                if line == b".":
                    return True, bytes(message)
                if line.startswith(b".."):
                    line = line[1:]
                if len(message) + len(line) + 2 > MAX_MIME_CAPTURE:
                    raise OSError("SMTP MIME capture exceeded bound")
                message.extend(line)
                message.extend(b"\r\n")


class AppRunner:
    def __init__(
        self,
        app_executable: pathlib.Path,
        app_argument: pathlib.Path,
        cli: pathlib.Path,
        root: pathlib.Path,
        log_root: pathlib.Path,
    ) -> None:
        self.app_executable = app_executable
        self.app_argument = app_argument
        self.cli_path = cli
        self.root = root
        self.log_root = log_root
        self.process: subprocess.Popen[bytes] | None = None
        self.log_handle: Any = None
        self.launch_count = 0

    def _environment(self, *, cli_secret: bool = False) -> dict[str, str]:
        environment = dict(os.environ)
        for key in (
            "MAILTERNAL_PASSWORD",
            "MAILTERNAL_TOKEN",
            "MAILTERNAL_BEARER_TOKEN",
            "MAILTERNAL_TLS_FINGERPRINT",
        ):
            environment.pop(key, None)
        environment.update(
            {
                "MAILTERNAL_QA": "1",
                "MAILTERNAL_QA_CERT": str(self.certificate),
                "MAILTERNAL_QA_USER": QA_USER,
                "MAILTERNAL_QA_PASSWORD": QA_PASSWORD,
                "MAILTERNAL_CONTAINER": str(self.root),
            }
        )
        if cli_secret:
            environment["MAILTERNAL_PASSWORD"] = QA_PASSWORD
        return environment

    @property
    def certificate(self) -> pathlib.Path:
        return self._certificate

    @certificate.setter
    def certificate(self, value: pathlib.Path) -> None:
        self._certificate = value

    def start(self, certificate: pathlib.Path) -> None:
        require(self.process is None, "Mailternal app is already running")
        self.certificate = certificate
        self.launch_count += 1
        log_path = self.log_root / f"app-{self.launch_count}.log"
        self.log_handle = log_path.open("wb")
        arguments = [
            "--mailternal-engine",
            "--mailternal-container",
            str(self.root),
            "-qa-account",
            IMAP_HOST,
            str(IMAP_PORT),
            IMAP_SECURITY,
            "-qa-container",
            str(self.root),
        ]
        self.process = subprocess.Popen(
            [str(self.app_executable), *arguments],
            cwd=str(self.root),
            env=self._environment(),
            stdin=subprocess.DEVNULL,
            stdout=self.log_handle,
            stderr=self.log_handle,
        )

    def stop(self) -> None:
        process, self.process = self.process, None
        if process is not None:
            if process.poll() is None:
                with contextlib.suppress(ProcessLookupError):
                    process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    with contextlib.suppress(ProcessLookupError):
                        process.kill()
                    with contextlib.suppress(subprocess.TimeoutExpired):
                        process.wait(timeout=5)
        if self.log_handle is not None:
            self.log_handle.close()
            self.log_handle = None

    def command(self, arguments: Iterable[str], *, expected: int | None = 0, secret: bool = False,
                password: str | None = None, start_runtime: bool = False) -> dict[str, Any]:
        command_arguments = list(arguments)
        command = [
            str(self.cli_path),
            "--container",
            str(self.root),
            "--app",
            str(self.app_argument),
            *([] if start_runtime else ["--no-start"]),
            *command_arguments,
        ]
        environment = self._environment(cli_secret=secret)
        if password is not None:
            environment["MAILTERNAL_PASSWORD"] = password
        try:
            completed = subprocess.run(
                command,
                env=environment,
                cwd=str(self.root),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=MAX_CLI_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise HarnessFailure(f"CLI timed out: {' '.join(command_arguments)}") from error
        stdout = completed.stdout.decode("utf-8", "replace")
        stderr = completed.stderr.decode("utf-8", "replace")
        with (self.log_root / "cli.log").open("a", encoding="utf-8") as handle:
            handle.write(f"$ {' '.join(command_arguments)}\n")
            handle.write(f"status={completed.returncode} stdout={stdout} stderr={stderr}\n")
        try:
            payload = json.loads(stdout)
        except json.JSONDecodeError as error:
            raise HarnessFailure(
                f"CLI returned non-JSON output for {' '.join(command_arguments)} (status {completed.returncode})"
            ) from error
        if expected is not None and completed.returncode != expected:
            raise HarnessFailure(
                f"CLI status {completed.returncode}, expected {expected} for {' '.join(command_arguments)}: "
                f"{payload.get('error', payload)}"
            )
        return payload

    def result(self, arguments: Iterable[str], *, secret: bool = False) -> Any:
        payload = self.command(arguments, secret=secret)
        require(payload.get("schema") == CLI_SCHEMA, f"unexpected CLI schema: {payload.get('schema')}")
        require(payload.get("ok") is True, f"CLI command failed: {payload.get('error', payload)}")
        require("result" in payload, "successful CLI result omitted result field")
        return payload["result"]

    def wait_ready(self) -> None:
        deadline = time.monotonic() + 45.0
        last_error = "runtime unavailable"
        while time.monotonic() < deadline:
            if self.process is not None and self.process.poll() is not None:
                raise HarnessFailure(f"Mailternal app exited during startup (status {self.process.returncode})")
            try:
                payload = self.command(["engine", "status"])
                runtime = payload.get("result", {})
                if payload.get("ok") is True and runtime.get("ready") is True:
                    require(runtime.get("kind") == "daemon", "private runtime is not headless")
                    require(self.process is not None and runtime.get("processID") == self.process.pid,
                            "runtime owner differs from the private app process")
                    return
                last_error = str(payload)
            except HarnessFailure as error:
                last_error = str(error)
            time.sleep(0.25)
        raise HarnessFailure(f"Mailternal app did not become ready: {last_error}")

    def state(self) -> dict[str, Any]:
        snapshot = self.command(["state"])
        require(snapshot.get("schema") == "mailternal.event.v1" and snapshot.get("kind") == "snapshot",
                "state did not return a snapshot event")
        value = snapshot.get("state")
        require(isinstance(value, dict), "state result is not an object")
        return value

    def account(self) -> dict[str, Any]:
        accounts = self.state().get("accounts")
        require(isinstance(accounts, list), "state result omitted accounts")
        for account in accounts:
            if isinstance(account, dict) and account.get("id") == QA_ACCOUNT:
                return account
        raise HarnessFailure(f"QA account {QA_ACCOUNT} is unavailable")


def poll(description: str, action: Callable[[], Any], predicate: Callable[[Any], bool], timeout: float = 60.0) -> Any:
    deadline = time.monotonic() + timeout
    last: Any = None
    while time.monotonic() < deadline:
        try:
            last = action()
            if predicate(last):
                return last
        except (HarnessFailure, OSError, imaplib.IMAP4.error) as error:
            last = str(error)
        time.sleep(0.25)
    raise HarnessFailure(f"timed out waiting for {description}; last value: {last}")


def draft_content(subject: str, body: str, *, recipient: str = "recipient@example.test") -> dict[str, Any]:
    return {
        "from": {"displayName": "Mailternal QA", "address": QA_USER},
        "to": [{"address": recipient}],
        "cc": [],
        "bcc": [],
        "replyTo": [],
        "subject": subject,
        "plainText": body,
        "references": [],
        "attachments": [],
    }


def write_json(root: pathlib.Path, name: str, value: Any) -> pathlib.Path:
    path = root / name
    path.write_text(json.dumps(value, sort_keys=True), encoding="utf-8")
    path.chmod(0o600)
    return path


def draft_get(app: AppRunner, draft_id: str) -> dict[str, Any]:
    value = app.result(["draft", "get", draft_id])
    require(isinstance(value, dict), f"draft get returned {value!r}")
    return value


def outbox_get(app: AppRunner, outbox_id: str) -> dict[str, Any]:
    value = app.result(["outbox", "get", outbox_id])
    require(isinstance(value, dict), f"outbox get returned {value!r}")
    return value


def create_draft(app: AppRunner, root: pathlib.Path, name: str, content: dict[str, Any]) -> dict[str, Any]:
    path = write_json(root, name, content)
    value = app.result(["draft", "create", "--account", QA_ACCOUNT, "--file", str(path)])
    require(isinstance(value, dict) and isinstance(value.get("id"), str), f"draft create returned {value!r}")
    return value

def send_draft(app: AppRunner, draft: dict[str, Any]) -> dict[str, Any]:
    value = app.result(["draft", "send", draft["id"], "--revision", str(draft["revision"])])
    require(isinstance(value, dict) and isinstance(value.get("id"), str), f"draft send returned {value!r}")
    return value


def wait_outbox(app: AppRunner, outbox_id: str, state: str, timeout: float = 90.0) -> dict[str, Any]:
    return poll(
        f"outbox {outbox_id} to be {state}",
        lambda: outbox_get(app, outbox_id),
        lambda value: isinstance(value, dict) and value.get("state") == state,
        timeout,
    )


def imap_connection(certificate: pathlib.Path) -> imaplib.IMAP4:
    context = ssl.create_default_context(cafile=str(certificate))
    previous_timeout = socket.getdefaulttimeout()
    socket.setdefaulttimeout(MAX_IMAP_SECONDS)
    try:
        connection = imaplib.IMAP4(IMAP_HOST, IMAP_PORT)
    finally:
        socket.setdefaulttimeout(previous_timeout)
    if connection.sock is not None:
        connection.sock.settimeout(MAX_IMAP_SECONDS)
    status, _ = connection.starttls(ssl_context=context)
    require(status == "OK", "QA IMAP STARTTLS failed")
    status, _ = connection.login(QA_USER, QA_PASSWORD)
    require(status == "OK", "QA IMAP login failed")
    return connection


def sent_uids(certificate: pathlib.Path, message_id: str, *, writable: bool = False) -> list[bytes]:
    connection = imap_connection(certificate)
    try:
        status, _ = connection.select("Sent", readonly=not writable)
        require(status == "OK", "QA IMAP Sent selection failed")
        status, data = connection.uid("SEARCH", None, "HEADER", "Message-ID", message_id)
        require(status == "OK", "QA IMAP Sent search failed")
        if not data or not data[0]:
            return []
        return data[0].split()
    finally:
        with contextlib.suppress(Exception):
            connection.logout()


def wait_sent(certificate: pathlib.Path, message_id: str, timeout: float = 45.0) -> None:
    poll(
        f"Sent copy {message_id}",
        lambda: sent_uids(certificate, message_id),
        lambda values: bool(values),
        timeout,
    )


def cleanup_sent(certificate: pathlib.Path, message_ids: Iterable[str]) -> list[str]:
    failures: list[str] = []
    for message_id in sorted(set(message_ids)):
        try:
            connection = imap_connection(certificate)
            try:
                status, _ = connection.select("Sent", readonly=False)
                require(status == "OK", "QA IMAP Sent selection failed during cleanup")
                status, data = connection.uid("SEARCH", None, "HEADER", "Message-ID", message_id)
                require(status == "OK", "QA IMAP Sent search failed during cleanup")
                uids = [] if not data or not data[0] else data[0].split()
                for uid in uids:
                    raw_uid = uid.decode("ascii")
                    status, _ = connection.uid("STORE", raw_uid, "+FLAGS", "(\\Deleted)")
                    require(status == "OK", f"could not mark generated Sent message {message_id}")
                    # UID EXPUNGE limits deletion to this generated UID.  Never
                    # call EXPUNGE without a UID: QA Sent has unrelated mail.
                    status, _ = connection.uid("EXPUNGE", raw_uid)
                    require(status == "OK", f"could not expunge generated Sent message {message_id}")
            finally:
                with contextlib.suppress(Exception):
                    connection.logout()
        except Exception as error:
            failures.append(f"{message_id}: {error}")
    return failures


@contextlib.contextmanager
def validating_imap_proxy() -> Iterable[int]:
    """Validate normally through a private proxy, then close its endpoint."""
    class Forwarder(socketserver.BaseRequestHandler):
        def handle(self) -> None:
            try:
                with socket.create_connection((IMAP_HOST, IMAP_PORT), timeout=MAX_IMAP_SECONDS) as upstream:
                    self.request.settimeout(MAX_IMAP_SECONDS)
                    peers = (self.request, upstream)
                    while True:
                        readable, _, _ = select.select(peers, [], [], MAX_IMAP_SECONDS)
                        if not readable:
                            return
                        for source in readable:
                            data = source.recv(64 * 1024)
                            if not data:
                                return
                            destination = upstream if source is self.request else self.request
                            destination.sendall(data)
            except OSError:
                return

    with socketserver.ThreadingTCPServer((IMAP_HOST, 0), Forwarder) as server:
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        thread.start()
        try:
            yield server.server_address[1]
        finally:
            server.shutdown()
            thread.join(timeout=5)


def account_config(account: dict[str, Any], *, enabled: bool, imap_port: int) -> dict[str, Any]:
    value = {
        "id": account["id"],
        "accountLinkID": account["accountLinkID"],
        "displayName": account["displayName"],
        "emailAddress": account["emailAddress"],
        "username": account["username"],
        "imap": {"host": IMAP_HOST if imap_port == IMAP_PORT else "127.0.0.1", "port": imap_port, "security": IMAP_SECURITY},
        "smtp": account.get("smtp"),
        "isEnabled": enabled,
    }
    require(value["smtp"] is not None, "SMTP configuration disappeared while preparing account update")
    return value


def run_scenario(args: argparse.Namespace) -> pathlib.Path:
    cli_path, app_path, app_argument = resolve_app(pathlib.Path(args.app))
    certificate = pathlib.Path(args.certificate).expanduser().resolve()
    private_key = pathlib.Path(args.private_key).expanduser().resolve()
    require(certificate.is_file(), f"QA certificate is missing: {certificate}")
    require(private_key.is_file(), f"QA private key is missing: {private_key}")

    owns_root = args.root is None
    if args.root is None:
        root = pathlib.Path(tempfile.mkdtemp(prefix="mailternal-smtp-qa-")).resolve()
    else:
        root = pathlib.Path(args.root).expanduser().resolve()
        if root.exists():
            require(root.is_dir() and not any(root.iterdir()), f"--root must be a new or empty private directory: {root}")
            owns_root = False
        else:
            root.mkdir(parents=True, mode=0o700)
            owns_root = True
    root.chmod(0o700)
    log_root = root / "logs"
    log_root.mkdir(mode=0o700)
    fixture = SMTPFixture(root, certificate, private_key)
    app = AppRunner(app_path, app_argument, cli_path, root, log_root)
    generated_message_ids: list[str] = []
    success = False
    try:
        fixture.start()
        app.start(certificate)
        app.wait_ready()
        pass_check("private headless app starts with the QA account and memory credentials")

        smtp_json = write_json(
            root,
            "smtp.json",
            {
                "host": "localhost",
                "port": fixture.port,
                "security": "startTLS",
                "username": QA_USER,
                "credentialReference": None,
            },
        )
        app.result(["account", "smtp", "configure", QA_ACCOUNT, "--file", str(smtp_json), "--use-imap-password"])
        account = app.account()
        require(account.get("smtp", {}).get("host") == "localhost", "SMTP configuration was not persisted")
        require(account.get("smtp", {}).get("port") == fixture.port, "SMTP fixture port was not persisted")
        require(account.get("smtp", {}).get("credentialReference") is None, "SMTP did not reuse the IMAP credential")
        pass_check("SMTP is configured through the explicit QA IMAP-password reuse path")

        app.result(["account", "smtp", "configure", QA_ACCOUNT, "--file", str(smtp_json)], secret=True)
        first_smtp = app.account()["smtp"]
        first_reference = first_smtp.get("credentialReference")
        require(isinstance(first_reference, str) and bool(first_reference), "separate SMTP password has no reference")
        replacement_json = write_json(root, "smtp-replacement.json", first_smtp)
        app.result(["account", "smtp", "configure", QA_ACCOUNT, "--file", str(replacement_json)], secret=True)
        committed_smtp = app.account()["smtp"]
        require(committed_smtp.get("credentialReference") != first_reference,
                "password replacement reused the live credential reference")
        committed_json = write_json(root, "smtp-committed.json", committed_smtp)
        rejected = app.command(
            ["account", "smtp", "configure", QA_ACCOUNT, "--file", str(committed_json)],
            expected=None, password="deliberately-invalid-qa-password",
        )
        require(rejected.get("ok") is False, "invalid SMTP replacement was accepted")
        require(app.account()["smtp"] == committed_smtp, "failed validation changed durable SMTP configuration")
        app.result(["account", "smtp", "configure", QA_ACCOUNT, "--file", str(committed_json), "--keep-password"])
        pass_check("SMTP replacement uses a fresh reference; failed validation retains usable committed credentials")
        # QA memory credentials intentionally do not survive process restart.
        app.result(["account", "smtp", "configure", QA_ACCOUNT, "--file", str(smtp_json), "--use-imap-password"])

        base = draft_content(f"Mailternal QA {uuid.uuid4()}", "first body")
        created = create_draft(app, root, "draft-create.json", base)
        require(created["revision"] == 1, f"new draft revision was {created.get('revision')}")
        completed = dict(base)
        completed["subject"] += " saved"
        completed["plainText"] = "saved body"
        completed_file = write_json(root, "draft-save.json", completed)
        save_result = app.result(["draft", "save", created["id"], "--revision", "1", "--file", str(completed_file)])
        require(save_result.get("saved", {}).get("revision") == 2, "draft save did not advance revision")
        loaded = draft_get(app, created["id"])
        require(loaded["revision"] == 2 and loaded["content"] == completed, "draft read did not return the saved complete value")
        pass_check("draft create/save/read completes a persisted revision")

        stale = dict(base)
        stale["subject"] += " stale fork"
        stale["plainText"] = "stale body"
        stale_file = write_json(root, "draft-stale.json", stale)
        fork_result = app.result(["draft", "save", created["id"], "--revision", "1", "--file", str(stale_file)])
        fork = fork_result.get("saved", {})
        require(fork.get("conflictOf") == created["id"], "stale save did not create a conflict fork")
        retained = draft_get(app, created["id"])
        fork_read = draft_get(app, fork["id"])
        require(retained["content"] == completed, "stale save overwrote the current draft")
        require(fork_read["content"] == stale, "stale save did not preserve the fork value")
        pass_check("stale revision forks preserve both draft values")

        attachment_data = bytes((index * 37 + 11) % 256 for index in range(700_123))
        attachment_path = root / "payload.bin"
        attachment_path.write_bytes(attachment_data)
        attachment_path.chmod(0o600)
        attach_result = app.result(
            [
                "draft",
                "attach",
                created["id"],
                "--file",
                str(attachment_path),
                "--filename",
                "qa-payload.bin",
                "--mime",
                "application/x-mailternal-qa",
            ]
        )
        current = draft_get(app, created["id"])
        require(current["revision"] == 3, "attachment upload did not save a new draft revision")
        attachments = current["content"].get("attachments", [])
        require(
            len(attachments) == 1
            and attachments[0].get("filename") == "qa-payload.bin"
            and attachments[0].get("mimeType") == "application/x-mailternal-qa"
            and attachments[0].get("byteCount") == len(attachment_data),
            "attachment metadata was not persisted",
        )
        attachment_id = attachments[0]["id"]
        downloaded = root / "downloaded.bin"
        app.result(["draft", "attachment", attachment_id, "--account", QA_ACCOUNT, "--output", str(downloaded)])
        require(downloaded.read_bytes() == attachment_data, "downloaded attachment hash/content differs")
        require(stat.S_IMODE(downloaded.stat().st_mode) == 0o600, "downloaded attachment is not mode 0600")
        require(hashlib.sha256(downloaded.read_bytes()).digest() == hashlib.sha256(attachment_data).digest(), "attachment hash differs")
        sentinel = root / "non-overwrite.bin"
        sentinel.write_bytes(b"do-not-overwrite")
        sentinel.chmod(0o600)
        overwrite = app.command(["draft", "attachment", attachment_id, "--account", QA_ACCOUNT, "--output", str(sentinel)], expected=None)
        require(overwrite.get("ok") is False, "attachment output unexpectedly overwrote an existing file")
        require(sentinel.read_bytes() == b"do-not-overwrite", "existing attachment output changed")
        pass_check("multi-chunk attachment upload/download verifies hash, name, MIME, 0600, and no overwrite")

        fixture.set_mode("reject_rcpt")
        rejected_before = fixture.completed_count()
        failed_send = send_draft(app, current)
        failed = wait_outbox(app, failed_send["id"], "failed")
        listed_failed = app.result(["outbox", "list", "--account", QA_ACCOUNT, "--limit", "50"])
        require(
            isinstance(listed_failed, list)
            and any(item.get("id") == failed_send["id"] and item.get("state") == "failed" for item in listed_failed if isinstance(item, dict)),
            "failed submission was not exposed by outbox list",
        )
        require(fixture.completed_count() == rejected_before, "RCPT rejection emitted a completed DATA message")
        preserved = draft_get(app, created["id"])
        require(preserved["content"] == current["content"], "RCPT rejection changed the draft or attachment")
        require(isinstance(failed.get("failure"), dict), "failed outbox omitted its SMTP failure")
        pass_check("RCPT rejection preserves draft/attachment and exposes a failed outbox")

        fixture.set_mode("accept")
        accepted_before = fixture.completed_count()
        app.result(["outbox", "retry", failed_send["id"]])
        sent = wait_outbox(app, failed_send["id"], "sent")
        require(fixture.completed_count() == accepted_before + 1, "successful retry did not complete exactly one DATA message")
        generated_message_ids.append(sent["messageID"])
        wait_sent(certificate, sent["messageID"])
        pass_check("failed SMTP submission retries and has an actual IMAP Sent copy")

        unknown_content = draft_content(f"Mailternal QA unknown {uuid.uuid4()}", "unknown body")
        unknown_draft = create_draft(app, root, "draft-unknown.json", unknown_content)
        fixture.set_mode("close_after_data")
        unknown_before = fixture.completed_count()
        unknown_send = send_draft(app, unknown_draft)
        unknown = wait_outbox(app, unknown_send["id"], "deliveryUnknown")
        require(fixture.completed_count() == unknown_before + 1, "unknown SMTP fixture did not observe completed DATA")
        generated_message_ids.append(unknown["messageID"])
        pass_check("missing final SMTP acceptance becomes deliveryUnknown")

        app.stop()
        fixture.set_mode("accept")
        app.start(certificate)
        app.wait_ready()
        time.sleep(2.0)
        after_restart = outbox_get(app, unknown_send["id"])
        require(after_restart["state"] == "deliveryUnknown", "app restart automatically resent deliveryUnknown")
        require(fixture.completed_count() == unknown_before + 1, "app restart emitted a second unknown DATA message")
        pass_check("restart preserves deliveryUnknown without automatic resend")

        refused = app.command(["outbox", "retry", unknown_send["id"]], expected=None)
        require(refused.get("ok") is False, "unknown retry without acknowledgement was not refused")
        require(outbox_get(app, unknown_send["id"])["state"] == "deliveryUnknown",
                "refused retry changed the unknown delivery state")
        require(fixture.completed_count() == unknown_before + 1, "refused retry submitted another message")
        pass_check("retrying deliveryUnknown without duplicate-risk acknowledgement is refused")
        retry_before = fixture.completed_count()
        app.result(["outbox", "retry", unknown_send["id"], "--acknowledge-duplicate-risk"])
        unknown_sent = wait_outbox(app, unknown_send["id"], "sent")
        require(fixture.completed_count() == retry_before + 1, "acknowledged unknown retry did not complete DATA")
        wait_sent(certificate, unknown_sent["messageID"])
        pass_check("explicit duplicate-risk retry sends and records a Sent copy")

        app.result(["account", "disable", QA_ACCOUNT])
        disabled = app.account()
        require(disabled.get("isEnabled") is False, "private QA account did not disable")
        with validating_imap_proxy() as offline_port:
            offline_config = account_config(disabled, enabled=False, imap_port=offline_port)
            offline_file = write_json(root, "account-imap-offline.json", offline_config)
            app.command(["account", "add", str(offline_file)], secret=True)
        updated = app.account()
        require(updated.get("isEnabled") is False and updated.get("imap", {}).get("port") == offline_port, "disabled IMAP endpoint update did not persist")
        require(updated.get("smtp") == disabled.get("smtp"), "disabled IMAP update did not retain SMTP settings")
        app.result(["account", "enable", QA_ACCOUNT])
        offline_content = draft_content(f"Mailternal QA Sent recovery {uuid.uuid4()}", "Sent recovery body")
        offline_draft = create_draft(app, root, "draft-sent-recovery.json", offline_content)
        fixture.set_mode("accept")
        sent_count_before = fixture.completed_count()
        offline_send = send_draft(app, offline_draft)
        pending = wait_outbox(app, offline_send["id"], "sentCopyPending", timeout=90.0)
        require(fixture.completed_count() == sent_count_before + 1, "SMTP acceptance did not occur before Sent-copy failure")
        generated_message_ids.append(pending["messageID"])
        pass_check("SMTP succeeds while offline IMAP leaves sentCopyPending")

        app.result(["account", "disable", QA_ACCOUNT])
        restored_config = account_config(app.account(), enabled=False, imap_port=IMAP_PORT)
        restored_file = write_json(root, "account-imap-restored.json", restored_config)
        app.command(["account", "add", str(restored_file)], secret=True)
        app.result(["account", "enable", QA_ACCOUNT])
        enabled = app.account()
        require(enabled.get("isEnabled") is True, "private QA account did not re-enable")
        app.result(["outbox", "retry", offline_send["id"]])
        recovered = wait_outbox(app, offline_send["id"], "sent", timeout=90.0)
        require(fixture.completed_count() == sent_count_before + 1, "Sent-copy retry incorrectly sent SMTP again")
        wait_sent(certificate, recovered["messageID"])
        pass_check("Sent-copy-only recovery never increments SMTP acceptance")

        cancel_content = draft_content(f"Mailternal QA cancellation {uuid.uuid4()}", "cancel body")
        cancel_draft = create_draft(app, root, "draft-cancel.json", cancel_content)
        cancel_attachment = root / "cancel-payload.bin"
        with cancel_attachment.open("wb") as handle:
            chunk = bytes((index * 19 + 7) % 256 for index in range(64 * 1024))
            for _ in range(256):
                handle.write(chunk)
        cancel_attachment.chmod(0o600)
        app.result(
            [
                "draft",
                "attach",
                cancel_draft["id"],
                "--file",
                str(cancel_attachment),
                "--filename",
                "cancel-payload.bin",
                "--mime",
                "application/octet-stream",
            ]
        )
        cancel_draft = draft_get(app, cancel_draft["id"])
        fixture.set_mode("hold_data")
        cancel_before = fixture.completed_count()
        cancel_send = send_draft(app, cancel_draft)
        poll("SMTP DATA phase to begin", lambda: fixture.data_started.is_set(), bool, 45.0)
        poll(
            f"outbox {cancel_send['id']} to remain pre-commit sending",
            lambda: outbox_get(app, cancel_send["id"]),
            lambda value: isinstance(value, dict) and value.get("state") == "sending",
            30.0,
        )
        app.result(["outbox", "cancel", cancel_send["id"]])
        fixture.release_hold()
        cancelled = wait_outbox(app, cancel_send["id"], "cancelled")
        require(fixture.completed_count() == cancel_before, "pre-commit cancellation emitted a completed DATA message")
        require(cancelled.get("state") == "cancelled", "pre-commit cancellation did not persist cancelled")
        pass_check("pre-commit cancellation emits no completed DATA message")

        auto_draft = create_draft(
            app, root, "draft-auto-owner.json",
            draft_content(f"Mailternal QA auto owner {uuid.uuid4()}", "Detached delivery owner"),
        )
        wrapper = root / "qa-owner"
        wrapper.write_text(
            "#!/bin/sh\nexec " + shlex.quote(str(app_path))
            + " -qa-account 127.0.0.1 1143 startTLS -qa-container "
            + shlex.quote(str(root)) + ' "$@"\n',
            encoding="utf-8",
        )
        wrapper.chmod(0o700)
        app.stop()
        original_argument = app.app_argument
        app.app_argument = wrapper
        try:
            fixture.set_mode("reject_rcpt")
            auto_response = app.command(
                ["draft", "send", auto_draft["id"], "--revision", str(auto_draft["revision"])],
                start_runtime=True,
            )
            require(auto_response.get("ok") is True, "auto-started draft send was not admitted")
            auto_submission = auto_response["result"]
            generated_message_ids.append(auto_submission["messageID"])
            wait_outbox(app, auto_submission["id"], "failed")
            require(app.result(["engine", "status"]).get("ready") is True,
                    "send stopped its newly started delivery owner")
            app.result(["engine", "stop"])
            poll("CLI-started owner shutdown",
                 lambda: app.command(["engine", "status"], expected=None),
                 lambda value: value.get("result", {}).get("state") == "not-running", timeout=15.0)
            fixture.set_mode("accept")
            auto_before = fixture.completed_count()
            retry_response = app.command(
                ["outbox", "retry", auto_submission["id"]], start_runtime=True,
            )
            require(retry_response.get("ok") is True, "auto-started outbox retry was not admitted")
            auto_sent = wait_outbox(app, auto_submission["id"], "sent", timeout=90.0)
            require(fixture.completed_count() == auto_before + 1,
                    "auto-started retry did not complete exactly one SMTP transaction")
            wait_sent(certificate, auto_sent["messageID"])
            pass_check("CLI-started send and retry owners outlive queue admission and finish actual delivery")
        finally:
            with contextlib.suppress(HarnessFailure):
                app.command(["engine", "stop"], expected=None)
            app.app_argument = original_argument
        success = True
        return root
    finally:
        fixture.stop()
        app.stop()
        cleanup_failures = cleanup_sent(certificate, generated_message_ids)
        if cleanup_failures:
            print("WARNING generated Sent-message cleanup failed: " + "; ".join(cleanup_failures), file=sys.stderr)
        if success and owns_root:
            shutil.rmtree(root, ignore_errors=False)
        elif not success:
            print(f"diagnostic root retained: {root}", file=sys.stderr)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Live SMTP/CLI QA smoke harness (macOS agents@mbp only)")
    parser.add_argument("--app", required=True, help="Mailternal.app bundle or app executable")
    parser.add_argument("--certificate", required=True, help="QA TLS certificate/CA PEM used by IMAP and SMTP fixture")
    parser.add_argument("--private-key", required=True, help="QA SMTP fixture private-key PEM")
    parser.add_argument("--root", "--private-run-root", dest="root", help="new private run root; retained on failure")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    if sys.platform != "darwin":
        print("smtp-delivery.py must run on macOS agents@mbp", file=sys.stderr)
        return 2
    args = parse_args(argv)
    try:
        run_scenario(args)
    except (HarnessFailure, OSError, ssl.SSLError, imaplib.IMAP4.error) as error:
        print(f"FAIL {error}", file=sys.stderr)
        return 1
    print("PASS SMTP/CLI delivery smoke harness complete", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
