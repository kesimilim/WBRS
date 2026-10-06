"""Bounded WSGI workers for this single-instance Timeweb stand.

Slow body/DB calls cannot serialize every API request. No request URL, token,
body or database exception is logged. Hosting TLS terminates upstream.
"""
import socket
import select
import threading
import time
from socketserver import ThreadingMixIn
from wsgiref.simple_server import WSGIRequestHandler, WSGIServer, ServerHandler, make_server


class _RequestBudget:
    """A request keeps its worker/media slot until the real handler settles."""
    def __init__(self, server, request):
        self.server = server; self.request = request
        self.cancel = threading.Event(); self._finished = threading.Event()
        self._lock = threading.RLock(); self._timer = None
        self._media = False; self._closed = False; self._generation = 0
        self._started = time.monotonic()
        self.deadline = self._started + server.REQUEST_DEADLINE_SECONDS

    def _arm(self):
        self._generation += 1
        generation = self._generation
        timer = threading.Timer(max(0, self.deadline - time.monotonic()),
            self._expire, args=(generation,))
        timer.daemon = True
        self._timer = timer
        timer.start()

    def start(self):
        with self._lock:
            self._arm()

    def _expire(self, generation):
        with self._lock:
            if self._closed or generation != self._generation:
                return
            self.abort()

    def abort(self):
        self.cancel.set()
        self.server._expire(self.request)

    def media(self):
        with self._lock:
            if (self._closed or self.cancel.is_set() or self._media
                    or time.monotonic() >= self.deadline
                    or not self.server._media_slots.acquire(blocking=False)):
                raise RuntimeError("Media unavailable")
            self._media = True
            try:
                self._timer.cancel()
                self.deadline = self._started + self.server.MEDIA_DEADLINE_SECONDS
                if time.monotonic() >= self.deadline:
                    raise RuntimeError("Media unavailable")
                self._arm()
                monitor = threading.Thread(target=self._monitor_disconnect, daemon=True)
                monitor.start()
                return self.deadline, self.cancel
            except Exception:
                self.abort()
                raise

    def _monitor_disconnect(self):
        # GET has no body. Peek never consumes a caller byte or a pipelined
        # request; EOF/reset cancels pre-response S3 I/O through the same event.
        while not self._finished.wait(.05):
            if self.cancel.is_set():
                return
            try:
                ready, _, _ = select.select([self.request], [], [], 0)
                if ready and self.request.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT) == b"":
                    self.abort(); return
            except (OSError, ValueError):
                self.abort(); return

    def close(self):
        with self._lock:
            if self._closed:
                return
            self._closed = True; self._generation += 1
            self.cancel.set(); self._finished.set()
            if self._timer is not None:
                self._timer.cancel()
            if self._media:
                self.server._media_slots.release()


class QuietServerHandler(ServerHandler):
    def log_exception(self, exc_info):
        # wsgiref otherwise prints the application's exception and traceback,
        # independently of RequestHandler.log_message/Server.handle_error.
        pass


class QuietRequestHandler(WSGIRequestHandler):
    def log_message(self, *args):
        pass

    def get_environ(self):
        environ = super().get_environ()
        environ["wsgi.multithread"] = True
        with self.server._budget_lock:
            budget = self.server._budgets.get(self.request)
        if budget is not None:
            environ["clrs.media_request_budget"] = budget.media
        return environ

    def handle(self):
        self.raw_requestline = self.rfile.readline(65537)
        if len(self.raw_requestline) > 65536:
            self.requestline = ""; self.request_version = ""; self.command = ""
            self.send_error(414)
            return
        if not self.parse_request():
            return
        handler = QuietServerHandler(self.rfile, self.wfile, self.get_stderr(),
                                     self.get_environ(), multithread=True)
        handler.request_handler = self
        handler.run(self.server.get_app())


class BoundedWSGIServer(ThreadingMixIn, WSGIServer):
    daemon_threads = True
    request_queue_size = 16
    MAX_WORKERS = 8
    SOCKET_TIMEOUT_SECONDS = 10
    REQUEST_DEADLINE_SECONDS = 10
    MEDIA_DEADLINE_SECONDS = 60
    MAX_MEDIA_WORKERS = 2

    def __init__(self, *args, **kwargs):
        self._slots = threading.BoundedSemaphore(self.MAX_WORKERS)
        self._media_slots = threading.BoundedSemaphore(self.MAX_MEDIA_WORKERS)
        self._stopping = threading.Event()
        self._budget_lock = threading.Lock(); self._budgets = {}
        super().__init__(*args, **kwargs)

    def process_request(self, request, client_address):
        if self._stopping.is_set():
            self.shutdown_request(request)
            return
        request.settimeout(self.SOCKET_TIMEOUT_SECONDS)
        if not self._slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\n"
                    b"Content-Type: application/json\r\nCache-Control: no-store\r\n"
                    b"Connection: close\r\nRetry-After: 1\r\nContent-Length: 31\r\n\r\n"
                    b'{"error":"service_unavailable"}')
            except (OSError, socket.timeout):
                pass
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._slots.release()
            self.shutdown_request(request)

    def process_request_thread(self, request, client_address):
        # A socket inactivity timeout alone permits an endless trickle of
        # bytes. An absolute deadline closes headers/body/response regardless
        # of that trickle; it never launches or retries an application write.
        budget = _RequestBudget(self, request)
        with self._budget_lock:
            self._budgets[request] = budget
        try:
            budget.start()
            if self._stopping.is_set():
                budget.abort()
                self.shutdown_request(request)
                return
            super().process_request_thread(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
            self.shutdown_request(request)
        finally:
            budget.close()
            with self._budget_lock:
                self._budgets.pop(request, None)
            self._slots.release()

    def _cancel_requests(self):
        # A worker dispatched just before shutdown may not have registered its
        # budget yet. It must observe this flag before starting the handler.
        self._stopping.set()
        with self._budget_lock:
            budgets = list(self._budgets.values())
        for budget in budgets:
            budget.abort()

    def shutdown(self):
        self._cancel_requests()
        super().shutdown()

    def server_close(self):
        self._cancel_requests()
        try:
            super().server_close()
        finally:
            close = getattr(self.get_app(), "close", None)
            if callable(close):
                try:
                    close()
                except Exception:
                    pass

    @staticmethod
    def _expire(request):
        try:
            request.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass

    def handle_error(self, request, client_address):
        # Never send a traceback or exception to public logs.
        pass


def make_bounded_server(host, port, application):
    return make_server(host, port, application, server_class=BoundedWSGIServer,
                       handler_class=QuietRequestHandler)
