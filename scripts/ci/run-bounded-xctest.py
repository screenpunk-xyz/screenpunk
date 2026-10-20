#!/usr/bin/env python3
"""Run an XCTest process with streamed output and a per-test deadline.

Stdout is a pseudoterminal so XCTest line-buffers "Test Case" events. A test
that does not finish within the deadline stops the process group. The suite
deadline still applies when a runner emits no per-test lines.
"""
import argparse
import os
import pty
import re
import select
import signal
import subprocess
import sys
import time

START = re.compile(r"Test Case '([^']+)' started")
END = re.compile(r"Test Case '([^']+)' (?:passed|failed|skipped)")


def kill_group(process):
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except OSError:
        return
    deadline = time.monotonic() + 5
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.1)
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except OSError:
            pass
        process.wait()


def sample_process(process):
    if not os.path.exists("/usr/bin/sample"):
        return
    try:
        subprocess.run(["sample", str(process.pid), "3"], timeout=15, check=False)
    except (OSError, subprocess.TimeoutExpired):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", required=True)
    parser.add_argument("--test-timeout-seconds", type=float, default=300)
    parser.add_argument("--suite-timeout-seconds", type=float, default=1500)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command and args.command[0] == "--" else args.command
    if not command:
        print("run-bounded-xctest.py: missing test command", file=sys.stderr)
        return 2
    os.makedirs(os.path.dirname(os.path.abspath(args.log)), exist_ok=True)
    log = open(args.log, "ab", buffering=0)
    master, slave = pty.openpty()
    env = os.environ.copy()
    env["NSUnbufferedIO"] = "YES"
    process = subprocess.Popen(
        command,
        stdout=slave,
        stderr=slave,
        stdin=subprocess.DEVNULL,
        env=env,
        start_new_session=True,
    )
    os.close(slave)
    started = time.monotonic()
    current = None
    current_started = None
    reason = None
    pending = b""

    def consume(chunk):
        nonlocal pending, current, current_started
        log.write(chunk)
        sys.stdout.buffer.write(chunk)
        sys.stdout.buffer.flush()
        pending += chunk
        while b"\n" in pending:
            raw, pending = pending.split(b"\n", 1)
            text = raw.decode("utf-8", "replace")
            started_match = START.search(text)
            if started_match:
                current = started_match.group(1)
                current_started = time.monotonic()
            if END.search(text):
                current = None
                current_started = None

    try:
        while True:
            now = time.monotonic()
            if now - started > args.suite_timeout_seconds:
                reason = "XCTest suite exceeded %.0fs" % args.suite_timeout_seconds
                break
            if current is not None and current_started is not None and now - current_started > args.test_timeout_seconds:
                reason = "XCTest '%s' exceeded %.0fs" % (current, args.test_timeout_seconds)
                break
            readable, _, _ = select.select([master], [], [], 1.0)
            if not readable:
                if process.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                if process.poll() is not None:
                    break
                continue
            consume(chunk)
        while True:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            consume(chunk)
    finally:
        os.close(master)
        log.close()
    if reason:
        print("::error::" + reason, flush=True)
        sample_process(process)
        kill_group(process)
        return 124
    return process.wait()


if __name__ == "__main__":
    sys.exit(main())
