"""Live check: is facebook.com blocked in LibreWolf / Firefox?

Same checks as fb_probe.py, driven over Marionette (no geckodriver needed):
direct loads the WebsiteFilter policy sees, and in-page route changes it
cannot see, which fb-spa-guard must catch.

Usage: fb_probe_firefox.py BROWSER_BINARY [direct|routes]
Exit 0 only if every check passes. Firefox loads slowly, so one call
running both halves can pass 60 s: run `direct` and `routes` separately.
"""

import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

PORT = 2828
GECKO_ID = "fb-spa-guard@hosts-blocker"
REEL = "/reel/872535709195049"
SETTLE_SECONDS = 4
INSTALL_WAIT_SECONDS = 30


class Marionette:
    """Minimal Marionette client: length-prefixed JSON over a socket."""

    def __init__(self) -> None:
        self.sock = socket.create_connection(("127.0.0.1", PORT), timeout=60)
        self.msg_id = 0
        self._read_message()  # server hello
        self.call("WebDriver:NewSession", {"capabilities": {}})

    def _read_message(self) -> object:
        header = b""
        while not header.endswith(b":"):
            header += self.sock.recv(1)
        length = int(header[:-1])
        data = b""
        while len(data) < length:
            data += self.sock.recv(length - len(data))
        return json.loads(data)

    def call(self, command: str, params: dict | None = None) -> dict:
        """Return the result, or {"error": ...} when the command failed."""
        self.msg_id += 1
        body = json.dumps([0, self.msg_id, command, params or {}])
        self.sock.sendall(f"{len(body)}:{body}".encode())
        while True:
            reply = self._read_message()
            if isinstance(reply, list) and reply[1] == self.msg_id:
                if reply[2]:
                    return {"error": str(reply[2].get("message", reply[2]))}
                return reply[3] if isinstance(reply[3], dict) else {"value": reply[3]}

    def run(self, script: str) -> str:
        result = self.call("WebDriver:ExecuteScript", {"script": script, "args": []})
        return str(result.get("value", result.get("error")))


def wait_for_guard(profile: Path) -> bool:
    deadline = time.time() + INSTALL_WAIT_SECONDS
    while time.time() < deadline:
        if (profile / "extensions" / f"{GECKO_ID}.xpi").exists():
            time.sleep(3)  # let the background script register its listeners
            return True
        time.sleep(1)
    return False


def main() -> int:
    profile = Path(tempfile.mkdtemp(prefix="fb-probe-ff-"))
    proc = subprocess.Popen(
        [
            sys.argv[1],
            "--headless",
            "--no-remote",
            "--marionette",
            "--profile",
            str(profile),
            "about:blank",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    part = sys.argv[2] if len(sys.argv) > 2 else "all"
    failures = 0

    def check(label: str, got: str, ok: bool) -> None:
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {label} -> {got}")

    def load(url: str) -> str:
        result = marionette.call("WebDriver:Navigate", {"url": url})
        return "blocked" if "error" in result else "ok"

    def route_in_page(route: str) -> str:
        if load("https://www.facebook.com/login/") != "ok":
            return "login page did not load"
        marionette.run("document.documentElement.setAttribute('data-fbprobe','1')")
        marionette.run(f"history.pushState({{}}, '', '{route}')")
        time.sleep(SETTLE_SECONDS)
        kept = marionette.run(
            "return document.documentElement.getAttribute('data-fbprobe')"
        )
        return "kept" if kept == "1" else "reloaded"

    try:
        for _ in range(40):
            try:
                marionette = Marionette()
                break
            except OSError:
                time.sleep(1)
        print(f"extension installed: {wait_for_guard(profile)}")
        if part in ("all", "direct"):
            for url in ("https://www.facebook.com" + REEL, "https://www.facebook.com/"):
                got = load(url)
                check(f"direct load {url} blocked", got, got == "blocked")
            for url in (
                "https://www.messenger.com/",
                "https://www.facebook.com/messages/t/1",
            ):
                got = load(url)
                check(f"direct load {url} allowed", got, got == "ok")
        if part in ("all", "routes"):
            for route in (REEL, "/", "/watch/"):
                got = route_in_page(route)
                check(f"in-page route to {route} rejected", got, got == "reloaded")
            got = route_in_page("/messages/t/1")
            check("in-page route to /messages/t/1 kept", got, got == "kept")
    finally:
        proc.kill()
    print("ALL PASS" if failures == 0 else f"{failures} FAILED")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
