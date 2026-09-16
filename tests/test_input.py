import dataclasses
import importlib.util
from pathlib import Path
import socket
import time
import unittest
from urllib.request import urlopen
from urllib.error import HTTPError

from websockets.sync.client import connect
from websockets.exceptions import ConnectionClosed, InvalidHandshake

from joystream_input import Receiver, State

ROOT = Path(__file__).resolve().parent.parent


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.pad = Receiver("127.0.0.1", 0).start()
        self.addCleanup(self.pad.close)
        self.url = f"ws://127.0.0.1:{self.pad.port}/ws"

    def wait_state(self, predicate, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            state = self.pad.read()
            if predicate(state):
                return state
            time.sleep(0.005)
        self.fail(f"State timed out: {self.pad.read()}")

    def test_http_browser_routes_and_non_websocket_requests(self):
        for path in ("/", "/index.html"):
            with urlopen(f"http://127.0.0.1:{self.pad.port}{path}", timeout=2) as response:
                self.assertEqual(response.read(), (ROOT / "index.html").read_bytes())
                self.assertEqual(response.headers.get_all("Content-Type"), ["text/html; charset=utf-8"])
        with self.assertRaises(HTTPError) as error:
            urlopen(f"http://127.0.0.1:{self.pad.port}/missing", timeout=2)
        self.assertEqual(error.exception.code, 404)

    def test_real_input_immutable_snapshots_and_disconnect(self):
        self.assertEqual(self.pad.read(), State())
        with connect(self.url) as phone:
            self.assertFalse(self.pad.read().connected)
            phone.send('{"lx":0.5,"ly":-2,"rx":2,"a":true,"start":1}')
            state = self.wait_state(lambda state: state.a == 1)
            self.assertEqual(state.axes, (0.5, -1.0, 1.0, 0.0))
            self.assertEqual(state.buttons, (1, 0, 0, 0, 0, 0, 0, 1))
            with self.assertRaises(dataclasses.FrozenInstanceError):
                state.a = 0
            phone.send('{"b":1}')
            other = self.wait_state(lambda state: state.b == 1)
            self.assertEqual(other.axes, (0, 0, 0, 0))
            self.assertEqual(other.a, 0)
            self.assertEqual(state.a, 1)
        self.wait_state(lambda state: state == State())

    def test_invalid_traffic_and_silence_do_not_hold_input(self):
        with connect(self.url) as phone:
            phone.send('{"a":1}')
            self.wait_state(lambda state: state.a == 1)
            for value in ('[]', 'null', '{"lx":NaN}', '{"ry":1e999}', '{"a":2}', '{"lx":"1"}', 'not JSON'):
                phone.send(value)
                time.sleep(0.1)
            self.assertEqual(self.pad.read(), State())
            phone.send('{"b":1}')
            self.wait_state(lambda state: state.b == 1)
            self.wait_state(lambda state: state == State())

    def test_heartbeat_fragmentation_binary_and_ping(self):
        with connect(self.url) as phone:
            for _ in range(7):
                phone.send(['{"ly":', '-1,"a":1}'])
                self.wait_state(lambda state: state.a == 1)
                time.sleep(0.1)
            self.assertTrue(self.pad.read().connected)
            self.assertEqual(self.pad.read().ly, -1)
            self.assertTrue(phone.ping(b"test").wait(1))
            phone.send(b'{"start":1}')
            self.wait_state(lambda state: state.start == 1)

    def test_takeover_and_late_old_message_cannot_overwrite(self):
        with connect(self.url) as old:
            old.send('{"a":1}')
            self.wait_state(lambda state: state.a == 1)
            with connect(self.url) as new:
                self.wait_state(lambda state: not state.connected)
                new.send('{"b":1}')
                self.wait_state(lambda state: state.b == 1)
                try:
                    old.send('{"a":1}')
                except ConnectionClosed:
                    pass
                time.sleep(0.05)
                self.assertEqual(self.pad.read().b, 1)
                self.assertEqual(self.pad.read().a, 0)

    def test_rejected_route_does_not_take_control(self):
        with connect(self.url) as phone:
            phone.send('{"a":1}')
            self.wait_state(lambda state: state.a == 1)
            with self.assertRaises(InvalidHandshake):
                with connect(self.url.replace('/ws', '/wrong')):
                    pass
            self.assertEqual(self.pad.read().a, 1)

    def test_oversized_message_releases_and_server_recovers(self):
        with connect(self.url) as phone:
            phone.send('{"a":1}')
            self.wait_state(lambda state: state.a == 1)
            phone.send(' ' * 5000)
            with self.assertRaises(ConnectionClosed):
                phone.recv(timeout=2)
        self.wait_state(lambda state: state == State())
        with connect(self.url) as phone:
            phone.send('{"b":1}')
            self.wait_state(lambda state: state.b == 1)

    def test_close_releases_clients_port_and_allows_restart(self):
        with connect(self.url) as phone:
            phone.send('{"a":1}')
            self.wait_state(lambda state: state.a == 1)
            self.pad.close()
            self.assertEqual(self.pad.read(), State())
            with self.assertRaises(ConnectionClosed):
                phone.recv(timeout=2)
        self.pad.close()
        with self.assertRaises(OSError):
            socket.create_connection(('127.0.0.1', self.pad.port), timeout=1)
        self.pad.start()
        self.assertIs(self.pad.start(), self.pad)
        with connect(self.url) as phone:
            phone.send('{"start":1}')
            self.wait_state(lambda state: state.start == 1)

    def test_bind_failure_is_synchronous(self):
        other = Receiver('127.0.0.1', self.pad.port)
        with self.assertRaises(OSError):
            other.start()
        other.close()
        self.assertEqual(other.read(), State())

    def test_context_manager_and_custom_timeout(self):
        with Receiver('127.0.0.1', 0, timeout=0.05) as receiver:
            with connect(f'ws://127.0.0.1:{receiver.port}/ws') as phone:
                phone.send('{"a":1}')
                deadline = time.monotonic() + 1
                while not receiver.read().connected and time.monotonic() < deadline:
                    time.sleep(0.001)
                self.assertEqual(receiver.read().a, 1)
                time.sleep(0.08)
                self.assertEqual(receiver.read(), State())
        for timeout in (0, -1, float('nan'), float('inf')):
            with self.assertRaises(ValueError):
                Receiver(timeout=timeout)


class CFClientAdapterTests(unittest.TestCase):
    def test_reader_contract_and_lost_input(self):
        from unittest.mock import patch
        spec = importlib.util.spec_from_file_location('cfclient_reader', ROOT / 'examples/cfclient_reader.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch.dict('os.environ', {'JOYSTREAM_HOST': '127.0.0.1', 'JOYSTREAM_PORT': '0'}):
            reader = module.JoystickReader()
        self.addCleanup(reader.receiver.close)
        self.assertEqual(reader.devices(), [{'id': 0, 'name': 'joystream'}])
        with self.assertRaises(OSError):
            reader.open(0)
        with connect(f'ws://127.0.0.1:{reader.receiver.port}/ws') as phone:
            phone.send('{"lx":0.25,"ly":-1,"a":1,"start":1}')
            deadline = time.monotonic() + 1
            while not reader.receiver.read().connected and time.monotonic() < deadline:
                time.sleep(0.005)
            reader.open(0)
            self.assertEqual(reader.read(0), [[0.25, -1, 0, 0], [1, 0, 0, 0, 0, 0, 0, 1]])
            reader.close(0)
            reader.open(0)
            time.sleep(0.55)
            with self.assertRaises(OSError):
                reader.read(0)


if __name__ == '__main__':
    unittest.main()
