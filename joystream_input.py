"""Embed joystream's HTTP/WebSocket receiver without a system gamepad.

    with Receiver() as pad:
        state = pad.read()  # immutable snapshot; disconnected/stale => neutral

Networking runs in background threads. Call read() from your existing loop.
"""
from dataclasses import dataclass
import json
import logging
import math
from pathlib import Path
from threading import Lock, Thread
from time import monotonic

from websockets.exceptions import ConnectionClosed, InvalidStatus
from websockets.sync.server import serve

AXES = ("lx", "ly", "rx", "ry")
BUTTONS = ("a", "b", "x", "y", "l1", "r1", "select", "start")


class _HTTPResponses(logging.Filter):
    def filter(self, record):
        # websockets 13 logs intentional plain HTTP responses as handshake
        # errors. Filter only our normal page / missing-route responses.
        error = record.exc_info[1] if record.exc_info else None
        return not (isinstance(error, InvalidStatus) and error.response.status_code in (200, 404))


_logger = logging.getLogger(__name__)
_logger.addFilter(_HTTPResponses())


@dataclass(frozen=True)
class State:
    """Normalized controls. connected means a valid snapshot arrived recently."""
    lx: float = 0.0
    ly: float = 0.0
    rx: float = 0.0
    ry: float = 0.0
    a: int = 0
    b: int = 0
    x: int = 0
    y: int = 0
    l1: int = 0
    r1: int = 0
    select: int = 0
    start: int = 0
    connected: bool = False

    @property
    def axes(self):
        return tuple(getattr(self, key) for key in AXES)

    @property
    def buttons(self):
        return tuple(getattr(self, key) for key in BUTTONS)


def _decode(message):
    source = json.loads(message)
    if not isinstance(source, dict):
        raise ValueError("Expected a state object")
    values = {}
    for key in AXES:
        value = source.get(key, 0)
        if not isinstance(value, (int, float)) or not math.isfinite(value):
            raise ValueError(f"Invalid axis: {key}")
        values[key] = float(max(-1.0, min(1.0, value)))
    for key in BUTTONS:
        value = source.get(key, 0)
        if not isinstance(value, (int, float)) or value not in (0, 1):
            raise ValueError(f"Invalid button: {key}")
        values[key] = int(value)
    return State(**values, connected=True)


class Receiver:
    """One phone at a time, serving the browser at / and input at /ws.

    start() binds synchronously and raises on errors such as a busy port.
    read() never waits for network input and returns neutral after timeout
    seconds without a valid message (default 0.5), on disconnect, or on close.
    Lifecycle calls are serialized; snapshots can be read from any thread.
    """
    def __init__(self, host="0.0.0.0", port=8000, *, timeout=0.5):
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("timeout must be finite and positive")
        self.host, self.port, self.timeout = host, port, timeout
        self._lock = Lock()
        self._lifecycle = Lock()
        self._state = State()
        self._updated = 0.0
        self._client = None
        self._connections = set()
        self._token = None
        self._server = self._thread = None

    def start(self):
        with self._lifecycle:
            if self._server is not None:
                return self
            token = object()
            page = Path(__file__).with_name("index.html").read_text(encoding="utf-8")

            def request(connection, request):
                if request.path == "/ws":
                    return None
                if request.path in ("/", "/index.html"):
                    response = connection.respond(200, page)
                    del response.headers["Content-Type"]
                    response.headers["Content-Type"] = "text/html; charset=utf-8"
                    response.headers["Cache-Control"] = "no-store"
                    return response
                return connection.respond(404, "Not found\n")

            server = serve(lambda ws: self._handle(ws, token), self.host, self.port,
                           process_request=request, compression=None, max_size=4096,
                           open_timeout=3, close_timeout=0.5, logger=_logger)
            with self._lock:
                self._token = token
            self.port = server.socket.getsockname()[1]
            self._server = server
            self._thread = Thread(target=self._run, args=(server, token),
                                  name="joystream", daemon=True)
            self._thread.start()
        return self

    def _run(self, server, token):
        try:
            server.serve_forever()
        finally:
            with self._lock:
                if self._token is token:
                    self._token = self._client = None
                    self._state = State()

    def read(self):
        with self._lock:
            if self._token is None or monotonic() - self._updated >= self.timeout:
                self._state = State()
            return self._state

    def _handle(self, connection, token):
        with self._lock:
            if self._token is not token:
                return
            self._connections.add(connection)
            previous = self._client
            self._client = connection
            self._state = State()
        if previous is not None:
            # A slow closing handshake must not delay input from the new phone.
            Thread(target=previous.close, daemon=True).start()
        try:
            for message in connection:
                try:
                    state = _decode(message)
                except (ValueError, TypeError, OverflowError, RecursionError):
                    continue
                with self._lock:
                    if self._token is not token or self._client is not connection:
                        break
                    self._state, self._updated = state, monotonic()
        except ConnectionClosed:
            pass
        finally:
            with self._lock:
                self._connections.discard(connection)
                if self._client is connection:
                    self._client = None
                    self._state = State()

    def close(self):
        with self._lifecycle:
            if self._server is None:
                return
            with self._lock:
                self._token = self._client = None
                self._state = State()
                connections = tuple(self._connections)
            # Explicitly close clients too: websockets 13's shutdown only
            # closes the listener; newer versions also close the connections.
            for connection in connections:
                connection.close()
            self._server.shutdown()
            self._thread.join()
            self._server = self._thread = None

    __enter__ = start

    def __exit__(self, *_):
        self.close()
