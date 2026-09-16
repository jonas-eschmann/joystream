"""Generate an XCTest run file for the direct-build fallback in run.sh."""
import plistlib
import subprocess
import sys

platform = subprocess.check_output(
    ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-platform-path"], text=True
).strip()

plistlib.dump(
    {
        "JoystreamTests": {
            "TestBundlePath": "__TESTHOST__/PlugIns/JoystreamTests.xctest",
            "TestHostPath": "__TESTROOT__/Debug-iphonesimulator/Joystream.app",
            "TestHostBundleIdentifier": sys.argv[1],
            "IsAppHostedTestBundle": True,
            "TestingEnvironmentVariables": {
                "DYLD_INSERT_LIBRARIES": "__TESTHOST__/Frameworks/libXCTestBundleInject.dylib",
                "DYLD_FRAMEWORK_PATH": "__TESTHOST__/Frameworks:" + platform + "/Developer/Library/Frameworks",
                "DYLD_LIBRARY_PATH": "__TESTHOST__/Frameworks:" + platform + "/Developer/usr/lib",
            },
        },
        "__xctestrun_metadata__": {"FormatVersion": 1},
    },
    sys.stdout.buffer,
)
