"""Run after installing joystream: python examples/read_input.py"""
from time import sleep
from joystream_input import Receiver

try:
    with Receiver() as pad:
        print(f"Open http://<this-computer's-IP>:{pad.port} on the phone.")
        while True:
            print(pad.read())
            sleep(0.1)
except KeyboardInterrupt:
    pass
