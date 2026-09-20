"""Run the Apple XCTest bundle with live output and a bounded failure path."""
import os
import signal
import subprocess
import sys


def main():
    process = subprocess.Popen(
        ["xcrun", "xctest", sys.argv[1]],
        env={**os.environ, "NSUnbufferedIO": "YES"},
        start_new_session=True,
    )
    try:
        return process.wait(timeout=600)
    except subprocess.TimeoutExpired:
        print("::error::Apple XCTest exceeded 10 minutes; the last started test is above.", flush=True)
        # Capture blocked stacks before stopping the entire test process group.
        try:
            subprocess.run(["sample", str(process.pid), "3"], timeout=15, check=False)
        except (OSError, subprocess.TimeoutExpired):
            pass
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        return 124


if __name__ == "__main__":
    sys.exit(main())
