"""Optional cfclient input reader (no system joystick required).

Install joystream into cfclient's Python environment. Copy this file into
cfclient/utils/input/inputreaders/ and add "cfclient_reader" to that package's
input_readers list. Start cfclient, connect the phone to port 8000, then select
the joystream device and configure its mapping in cfclient.

Axes: lx, ly, rx, ry. Buttons: A, B, X, Y, L1, R1, Select, Start.
JOYSTREAM_HOST / JOYSTREAM_PORT override the listening address.
"""
import atexit
import os

from joystream_input import Receiver

MODULE_MAIN = "JoystickReader"
MODULE_NAME = "joystream"


class JoystickReader:
    def __init__(self):
        self.name = MODULE_NAME
        # Bind before device selection so the phone can connect first.
        self.receiver = Receiver(os.environ.get("JOYSTREAM_HOST", "0.0.0.0"),
                                 int(os.environ.get("JOYSTREAM_PORT", "8000"))).start()
        atexit.register(self.receiver.close)

    def devices(self):
        return [{"id": 0, "name": "joystream"}]

    def open(self, device_id):
        self.read(device_id)

    def close(self, device_id):
        # cfclient calls this when pausing/switching input devices. Keep the
        # listener available so the phone can reconnect before reselection.
        pass

    def read(self, device_id):
        if device_id != 0:
            raise ValueError("Unknown joystream device")
        state = self.receiver.read()
        if not state.connected:
            # cfclient's existing error handler sends zero thrust and stops
            # polling. Raw centered axes alone aren't safe in every mapping.
            raise OSError("joystream phone disconnected or silent; reconnect and reselect the device")
        return [list(state.axes), list(state.buttons)]
