import asyncio
import datetime
import json
import os
from pathlib import Path
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / "macos/.build/JoystreamServer-Diagnostics.app"
SERVER = APP / "Contents/MacOS/JoystreamServer"


def build_server():
    sources = list((ROOT / "macos").glob("*.swift")) + [ROOT / "index.html", ROOT / "macos/Package.resolved"]
    if not SERVER.exists() or any(p.stat().st_mtime > SERVER.stat().st_mtime for p in sources):
        subprocess.run([str(ROOT / "macos/run.sh"), "build", "--unsigned"], check=True)


@unittest.skipUnless(sys.platform == "darwin", "native macOS codec tests")
class NativeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        build_server()

    def encode(self, state):
        result = subprocess.run([str(SERVER), "--encode"], input=json.dumps(state) + "\n",
                                capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_neutral_report_layout(self):
        report = self.encode({})
        self.assertEqual(report["hid"], [1, 0, 128, 0, 128, 0, 128, 0, 128] + [0] * 8)
        self.assertEqual(report["gip"], [0x20, 0, 0, 15] + [0] * 15)

    def test_all_button_positions(self):
        positions = {"a": (14, 1, 4, 16), "b": (14, 2, 4, 32), "x": (14, 8, 4, 64),
                     "y": (14, 16, 4, 128), "l1": (14, 64, 5, 16), "r1": (14, 128, 5, 32),
                     "select": (15, 4, 4, 8), "start": (15, 8, 4, 4)}
        for button, (hi, hb, gi, gb) in positions.items():
            with self.subTest(button=button):
                report = self.encode({button: 1})
                self.assertEqual(report["hid"][hi], hb)
                self.assertEqual(report["gip"][gi], gb)
        both = self.encode(dict.fromkeys(positions, 1))
        self.assertEqual(both["hid"][14:16], [0xdb, 0x0c])
        self.assertEqual(both["gip"][4:6], [0xfc, 0x30])

    def test_axis_direction_ranges_and_sdl_fragment_flag(self):
        report = self.encode({"lx": -2, "ly": -1, "rx": 1, "ry": 2})
        self.assertEqual(struct.unpack_from("<4H", bytes(report["hid"]), 1), (0, 65535, 65535, 0))
        self.assertEqual(struct.unpack_from("<4h", bytes(report["gip"]), 10), (-32767, -32767, 32767, 32767))
        for value in (-1, -0.75, -0.5, -0.1, 0, 0.1, 0.5, 0.75, 1):
            self.assertEqual(self.encode({"lx": value})["hid"][1] & 0x80, 0)

    def test_descriptor_report_sizes_match_encoder(self):
        # Parse HID short items, independently of the codec's layout constants.
        descriptor = json.loads(subprocess.check_output([str(SERVER), "--descriptor"]))
        counts = {"input": {}, "output": {}}
        size = count = report_id = 0
        index = 0
        while index < len(descriptor):
            prefix = descriptor[index]
            length = (0, 1, 2, 4)[prefix & 3]
            value = int.from_bytes(bytes(descriptor[index + 1:index + 1 + length]), "little")
            kind, tag = (prefix >> 2) & 3, prefix >> 4
            if kind == 1:
                if tag == 7: size = value
                elif tag == 8: report_id = value
                elif tag == 9: count = value
            elif kind == 0 and tag in (8, 9):
                direction = "input" if tag == 8 else "output"
                counts[direction][report_id] = counts[direction].get(report_id, 0) + size * count
            index += 1 + length
        self.assertEqual(counts["input"], {1: 128, 7: 40, 32: 144})
        self.assertEqual(counts["output"], {3: 64})

    def test_unsigned_live_mode_fails_with_actionable_error(self):
        result = subprocess.run([str(SERVER), "--check"], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Virtual HID entitlement", result.stderr)
        self.assertNotIn("JOYSTREAM_SERVER_READY", result.stdout)

    def test_cli_help_and_invalid_options(self):
        result = subprocess.run([str(SERVER), "--help"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("--dry-run", result.stdout)
        for arguments in (["--port", "-1"], ["--port", "65536"], ["--host"], ["--check", "--dry-run"], ["--unknown"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run([str(SERVER), *arguments], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("JOYSTREAM_SERVER_READY", result.stdout)

    def test_native_parser_rejects_invalid_state(self):
        for text in ('[]', '{"lx":"bad"}', '{"a":2}', '{"rx":1e999}', 'not json'):
            with self.subTest(text=text):
                result = subprocess.run([str(SERVER), "--encode"], input=text + "\n",
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")


@unittest.skipUnless(sys.platform == "darwin", "native Swift builder validation")
class SigningTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        source = (ROOT / "macos/build.swift").read_text().split("// Command-line entry point.")[0]
        # Compile the production profile validator, with a test-only entry point.
        source += '''
do {
    let (bundle, allowed) = try profileSettings(plist(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))))
    let result = try JSONSerialization.data(withJSONObject: ["bundle": bundle, "entitlements": allowed])
    print(String(decoding: result, as: UTF8.self))
} catch { print(error); exit(1) }
'''
        fixture = Path(cls.temp.name) / "validate.swift"
        fixture.write_text(source)
        cls.validator = Path(cls.temp.name) / "validate"
        subprocess.run(["xcrun", "swiftc", str(fixture), "-o", str(cls.validator)], check=True)

    def profile(self):
        return {
            "ExpirationDate": datetime.datetime.now() + datetime.timedelta(days=1),
            "ApplicationIdentifierPrefix": ["ABCDE12345"],
            "Entitlements": {
                "com.apple.developer.hid.virtual.device": True,
                "com.apple.application-identifier": "ABCDE12345.org.example.joystream",
                "com.apple.developer.team-identifier": "ABCDE12345",
                "unrelated.permission": True,
            },
        }

    def validate(self, profile):
        file = Path(self.temp.name) / "profile.plist"
        file.write_bytes(plistlib.dumps(profile))
        return subprocess.run([str(self.validator), str(file)], capture_output=True, text=True)

    def test_profile_identity_and_minimal_entitlements(self):
        result = self.validate(self.profile())
        self.assertEqual(result.returncode, 0, result.stdout)
        value = json.loads(result.stdout)
        self.assertEqual(value["bundle"], "org.example.joystream")
        self.assertEqual(len(value["entitlements"]), 3)

    def test_reject_invalid_profiles(self):
        for mode in ("missing", "expired", "wildcard", "team", "empty_bundle"):
            profile = self.profile()
            if mode == "missing": del profile["Entitlements"]["com.apple.developer.hid.virtual.device"]
            elif mode == "expired": profile["ExpirationDate"] = datetime.datetime(2000, 1, 1)
            elif mode == "wildcard": profile["Entitlements"]["com.apple.application-identifier"] = "ABCDE12345.*"
            elif mode == "team": del profile["Entitlements"]["com.apple.developer.team-identifier"]
            else: profile["Entitlements"]["com.apple.application-identifier"] = "ABCDE12345."
            with self.subTest(mode=mode):
                self.assertNotEqual(self.validate(profile).returncode, 0)


@unittest.skipUnless(sys.platform == "darwin", "native macOS HTTP/WebSocket tests")
class NetworkTests(unittest.IsolatedAsyncioTestCase):
    @classmethod
    def setUpClass(cls):
        build_server()
        cls.temp = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.temp.cleanup)
        cls.probe = Path(cls.temp.name) / "client-probe"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5",
                        str(ROOT / "tests/SwiftClientProbe.swift"),
                        str(ROOT / "ios/Joystream/GamepadClient.swift"),
                        str(ROOT / "ios/Joystream/GamepadState.swift"), "-o", str(cls.probe)], check=True)

    async def asyncSetUp(self):
        self.process = await asyncio.create_subprocess_exec(
            str(SERVER), "--dry-run", "--host", "127.0.0.1", "--port", "0",
            stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL)
        self.neutral = json.loads(await asyncio.wait_for(self.process.stdout.readline(), 5))
        ready = await asyncio.wait_for(self.process.stdout.readline(), 5)
        self.assertTrue(ready.startswith(b"JOYSTREAM_SERVER_READY "), ready)
        self.port = int(ready.split()[1])
        self.url = f"ws://127.0.0.1:{self.port}/ws"
        self.reports = []
        self.pending = asyncio.Queue()
        async def read_reports():
            while line := await self.process.stdout.readline():
                report = json.loads(line)
                self.reports.append(report)
                await self.pending.put(report)
        self.reader = asyncio.create_task(read_reports())

    async def asyncTearDown(self):
        if self.process.returncode is None:
            self.process.terminate()
        try:
            await asyncio.wait_for(self.process.wait(), 3)
        except asyncio.TimeoutError:
            self.process.kill()
            await self.process.wait()
        await self.reader

    async def report(self, predicate, timeout=2):
        async def read():
            while True:
                value = await self.pending.get()
                if predicate(value): return value
        return await asyncio.wait_for(read(), timeout)

    async def http(self, path="/", method="GET"):
        reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
        try:
            writer.write(f"{method} {path} HTTP/1.1\r\nHost: localhost\r\n\r\n".encode())
            await writer.drain()
            response = await asyncio.wait_for(reader.read(), 3)
            header, body = response.split(b"\r\n\r\n", 1)
            return int(header.split()[1]), header, body
        finally:
            writer.close()
            await writer.wait_closed()

    async def test_bundled_browser_and_http_routes(self):
        for path in ("/", "/index.html"):
            status, header, body = await self.http(path)
            self.assertEqual(status, 200)
            self.assertEqual(body, (ROOT / "index.html").read_bytes())
            self.assertIn(b"text/html", header)
        self.assertEqual((await self.http("/missing"))[0], 404)
        self.assertEqual((await self.http("/ws"))[0], 426)
        self.assertEqual((await self.http("/", "POST"))[0], 405)
        status, header, body = await self.http("/", "HEAD")
        self.assertEqual(status, 200)
        self.assertEqual(body, b"")
        self.assertIn(str(len((ROOT / "index.html").read_bytes())).encode(), header)

    async def test_input_disconnect_and_ping(self):
        async with connect(self.url) as client:
            await client.send('{"lx":0.5,"ly":-1,"a":1}')
            report = await self.report(lambda x: x["hid"][14] == 1)
            self.assertEqual(struct.unpack_from("<4h", bytes(report["gip"]), 10), (16384, -32767, 0, 0))
            pong = await client.ping(b"joystream")
            await asyncio.wait_for(pong, 1)
        await self.report(lambda x: x == self.neutral)

    async def test_silence_and_invalid_traffic_release_controls(self):
        async with connect(self.url) as client:
            await client.send('{"a":1}')
            await self.report(lambda x: x["hid"][14] == 1)
            for invalid in ('not json', '[]', '{"a":2}', '{"lx":"bad"}', '{"rx":1e999}', '{"ry":null}', '{"b":-1}'):
                await client.send(invalid)
                await asyncio.sleep(0.1)
            await self.report(lambda x: x == self.neutral)
            await client.send('{"b":1}')
            await self.report(lambda x: x["hid"][14] == 2)
            await self.report(lambda x: x == self.neutral)

    async def test_heartbeat_holds_and_takeover_resets(self):
        async with connect(self.url) as old:
            for _ in range(7):
                await old.send('{"a":1}')
                await self.report(lambda x: x["hid"][14] == 1)
                await asyncio.sleep(0.1)
            self.assertEqual(self.reports[-1]["hid"][14], 1)
            async with connect(self.url) as new:
                await self.report(lambda x: x == self.neutral)
                await new.send('{"b":1}')
                await self.report(lambda x: x["hid"][14] == 2)
                await asyncio.wait_for(old.wait_closed(), 2)
                await asyncio.sleep(0.05)
                self.assertEqual(self.reports[-1]["hid"][14], 2)

    async def test_fragmented_and_binary_messages(self):
        async with connect(self.url) as client:
            await client.send(['{"a":', '1,"ly":', '-1}'])
            report = await self.report(lambda x: x["hid"][14] == 1)
            self.assertEqual(struct.unpack_from("<h", bytes(report["gip"]), 12)[0], -32767)
            await client.send(b'{"start":1}')
            await self.report(lambda x: x["hid"][15] == 8)

    async def test_actual_iphone_client_heartbeat_and_disconnect(self):
        process = await asyncio.create_subprocess_exec(str(self.probe), self.url,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        try:
            report = await self.report(lambda x: x["hid"][15] == 8)
            self.assertEqual(struct.unpack_from("<h", bytes(report["gip"]), 12)[0], -32767)
            await asyncio.sleep(0.7)
            self.assertEqual(self.reports[-1]["hid"][15], 8)
            self.assertGreater(sum(x["hid"][15] == 8 for x in self.reports), 4)
            _, errors = await asyncio.wait_for(process.communicate(), 3)
            self.assertEqual(process.returncode, 0, errors)
            await self.report(lambda x: x == self.neutral)
        finally:
            if process.returncode is None:
                process.kill()
                await process.communicate()

    async def test_relocated_bundle_without_python_or_source_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "JoystreamServer.app"
            shutil.copytree(APP, app)
            subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
            process = await asyncio.create_subprocess_exec(
                str(app / "Contents/MacOS/JoystreamServer"), "--dry-run", "--host", "127.0.0.1", "--port", "0",
                cwd=temporary, env={**os.environ, "PATH": "/nonexistent"},
                stdin=asyncio.subprocess.DEVNULL, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
            try:
                self.assertEqual(json.loads(await asyncio.wait_for(process.stdout.readline(), 3)), self.neutral)
                ready = await asyncio.wait_for(process.stdout.readline(), 3)
                self.assertTrue(ready.startswith(b"JOYSTREAM_SERVER_READY "), ready)
                port = int(ready.split()[1])
                reader, writer = await asyncio.open_connection("127.0.0.1", port)
                writer.write(b"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
                await writer.drain()
                response = await asyncio.wait_for(reader.read(), 3)
                writer.close()
                await writer.wait_closed()
                self.assertEqual(response.split(b"\r\n\r\n", 1)[1], (ROOT / "index.html").read_bytes())
                self.assertTrue((app / "Contents/Frameworks/libswiftCompatibilitySpan.dylib").is_file())
            finally:
                if process.returncode is None: process.terminate()
                await asyncio.wait_for(process.communicate(), 3)

    async def test_oversized_messages_close_and_release(self):
        for fragmented in (False, True):
            async with connect(self.url) as client:
                await client.send('{"a":1}')
                await self.report(lambda x: x["hid"][14] == 1)
                payload = [' ' * 2200, ' ' * 2200] if fragmented else ' ' * 5000
                try: await client.send(payload)
                except ConnectionClosed: pass
                await asyncio.wait_for(client.wait_closed(), 2)
                await self.report(lambda x: x == self.neutral)
        self.assertIsNone(self.process.returncode)

    async def test_wrong_endpoint_does_not_take_control(self):
        async with connect(self.url) as client:
            await client.send('{"a":1}')
            await self.report(lambda x: x["hid"][14] == 1)
            from websockets.exceptions import InvalidStatus
            with self.assertRaises(InvalidStatus):
                async with connect(self.url.replace("/ws", "/elsewhere")): pass
            self.assertEqual(self.reports[-1]["hid"][14], 1)

    async def test_sigterm_releases_and_closes_listener(self):
        async with connect(self.url) as client:
            await client.send('{"start":1}')
            await self.report(lambda x: x["hid"][15] == 8)
            self.process.terminate()
            await self.report(lambda x: x == self.neutral)
            self.assertEqual(await asyncio.wait_for(self.process.wait(), 2), 0)
            await asyncio.wait_for(client.wait_closed(), 2)
        with self.assertRaises(OSError):
            await asyncio.open_connection("127.0.0.1", self.port)

    async def test_port_conflict_fails_without_ready_marker(self):
        process = await asyncio.create_subprocess_exec(
            str(SERVER), "--dry-run", "--host", "127.0.0.1", "--port", str(self.port),
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        output, errors = await asyncio.wait_for(process.communicate(), 3)
        self.assertNotEqual(process.returncode, 0)
        self.assertNotIn(b"JOYSTREAM_SERVER_READY", output)
        self.assertIn(b"Address already in use", errors)
        self.assertEqual(json.loads(output.splitlines()[-1]), self.neutral)

    async def test_invalid_websocket_frames_are_rejected(self):
        from websockets.frames import Frame, Opcode
        for frame in (Frame(Opcode.TEXT, b'{"a":1}'), Frame(Opcode.CONT, b'{}'), Frame(Opcode.TEXT, b'\xff')):
            reader, writer = await asyncio.open_connection("127.0.0.1", self.port)
            try:
                writer.write(b"GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n")
                await writer.drain()
                header = await asyncio.wait_for(reader.readuntil(b"\r\n\r\n"), 2)
                self.assertIn(b"101 Switching Protocols", header)
                # First case is unmasked; the others use masking but violate sequencing/UTF-8.
                writer.write(frame.serialize(mask=frame.data != b'{"a":1}'))
                await writer.drain()
                response = await asyncio.wait_for(reader.read(), 2)
                self.assertEqual(response[0] & 15, 8)
                self.assertIsNone(self.process.returncode)
            finally:
                writer.close()
                await writer.wait_closed()


if __name__ == "__main__":
    unittest.main()
