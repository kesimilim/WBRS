"""Exercise the real HTTP admission gate, before any profile-photo service."""
import concurrent.futures
import socket
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

from http_runtime import _RequestBudget, make_bounded_server


class MediaQueueHttpTests(unittest.TestCase):
    def test_waiting_limit_disconnect_timeout_and_shutdown_release_capacity(self):
        for reason in ('disconnect', 'timeout', 'shutdown'):
            with self.subTest(reason=reason):
                server = make_bounded_server('127.0.0.1', 0, lambda *args: [])
                server._media_slots = threading.BoundedSemaphore(1)
                server._media_waiting_slots = threading.BoundedSemaphore(1)
                server.MEDIA_QUEUE_SECONDS = .2 if reason == 'timeout' else 1
                server._media_slots.acquire()
                peers = [socket.socketpair() for _ in range(3)]
                budgets = [_RequestBudget(server, pair[0]) for pair in peers]
                for budget in budgets:
                    budget.start()
                held = True
                try:
                    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                        waiter = pool.submit(budgets[0].media)
                        until = time.monotonic() + .5
                        while server._media_waiting_slots._value and time.monotonic() < until:
                            time.sleep(.005)
                        self.assertEqual(server._media_waiting_slots._value, 0)
                        if reason != 'timeout':
                            # A full waiting queue must refuse without waiting
                            # for the occupied media handler to finish.
                            start = time.monotonic()
                            with self.assertRaises(RuntimeError):
                                budgets[1].media()
                            self.assertLess(time.monotonic() - start, .2)
                        if reason == 'disconnect':
                            peers[0][1].close()
                        elif reason == 'shutdown':
                            server._stopping.set()
                        with self.assertRaises(RuntimeError):
                            waiter.result(timeout=1)
                        self.assertEqual(server._media_waiting_slots._value, 1)
                        self.assertEqual(server._media_slots._value, 0)
                    server._media_slots.release()
                    held = False
                    if reason != 'shutdown':
                        deadline, cancel = budgets[2].media()
                        self.assertGreater(deadline, time.monotonic())
                        self.assertFalse(cancel.is_set())
                        budgets[2].close()
                        self.assertEqual(server._media_slots._value, 1)
                finally:
                    for budget in budgets:
                        budget.close()
                    for pair in peers:
                        for peer in pair:
                            peer.close()
                    if held:
                        server._media_slots.release()
                    server.server_close()

    def test_four_photos_wait_without_blocking_health(self):
        release = threading.Event()
        all_entered = threading.Event()
        lock = threading.Lock()
        entered = active = peak = 0

        def application(environ, respond):
            nonlocal entered, active, peak
            if environ['PATH_INFO'] == '/photo':
                with lock:
                    entered += 1
                    if entered == 4:
                        all_entered.set()
                try:
                    environ['clrs.media_request_budget']()
                except RuntimeError:
                    respond('503 Service Unavailable', [('Content-Length', '4')])
                    return [b'busy']
                with lock:
                    active += 1
                    peak = max(peak, active)
                try:
                    release.wait(3)
                    time.sleep(.05)
                finally:
                    with lock:
                        active -= 1
            respond('200 OK', [('Content-Length', '2')])
            return [b'ok']

        server = make_bounded_server('127.0.0.1', 0, application)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        base = f'http://127.0.0.1:{server.server_port}'

        def photo():
            try:
                with urlopen(base + '/photo', timeout=4) as response:
                    return response.status, response.read()
            except HTTPError as response:
                return response.code, response.read()

        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                results = [pool.submit(photo) for _ in range(4)]
                try:
                    self.assertTrue(all_entered.wait(2))
                    with urlopen(base + '/healthz', timeout=1) as response:
                        self.assertEqual(response.read(), b'ok')
                finally:
                    release.set()
                self.assertEqual([result.result() for result in results], [(200, b'ok')] * 4)
            self.assertLessEqual(peak, 2)
            self.assertEqual(active, 0)
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            thread.join(2)


if __name__ == '__main__':
    unittest.main()
