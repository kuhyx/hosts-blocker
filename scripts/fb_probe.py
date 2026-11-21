"""Live check: is facebook.com blocked in one Chromium-family browser?

Launches the browser headless with a throw-away profile (so the live
managed policy applies, force-installed extensions included), then drives it
over the DevTools protocol. Two attack paths are probed:

* direct loads, which the URLBlocklist policy sees;
* in-page route changes (history.pushState) from a facebook.com page the
  allowlist lets through, which the policy never sees. This is how the
  reel at /reel/872535709195049 opened despite the policy.

Usage: fb_probe.py BROWSER_BINARY   (exit 0 only if every check passes)
"""

import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.request
from pathlib import Path

import websocket

PORT = 9333
BLOCKED = "net::ERR_BLOCKED_BY_ADMINISTRATOR"
REEL = "/reel/872535709195049"
SETTLE_SECONDS = 4
SW_WAIT_SECONDS = int(os.environ.get("FB_PROBE_WAIT", "20"))
# The guard's extension id, second field of the installer's stamp file.
STAMP = Path("/usr/share/hosts-blocker/fb-spa-guard/.stamp")
GUARD_ID = STAMP.read_text().split()[1] if STAMP.exists() else "none"


class Probe:
    """One DevTools session on the first page target."""

    def __init__(self, binary: str) -> None:
        profile = tempfile.mkdtemp(prefix="fb-probe-")
        self.proc = subprocess.Popen(
            [
                binary,
                "--headless=new",
                "--no-sandbox",
                "--disable-gpu",
                f"--remote-debugging-port={PORT}",
                f"--user-data-dir={profile}",
                "about:blank",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.msg_id = 0
        self.ws = websocket.create_connection(self._page_ws())
        self.call("Page.enable")

    def _targets(self) -> list[dict]:
        for _ in range(40):
            try:
                url = f"http://127.0.0.1:{PORT}/json"
                return json.load(urllib.request.urlopen(url))
            except OSError:
                time.sleep(0.5)
        raise RuntimeError("browser did not open its debugging port")

    def _page_ws(self) -> str:
        return next(t for t in self._targets() if t["type"] == "page")[
            "webSocketDebuggerUrl"
        ]

    def wait_for_extension(self) -> bool:
        """Force-installed extensions arrive async on a fresh profile."""
        deadline = time.time() + SW_WAIT_SECONDS
        while time.time() < deadline:
            if any(
                t["type"] == "service_worker"
                and t["url"].startswith(f"chrome-extension://{GUARD_ID}/")
                for t in self._targets()
            ):
                return True
            time.sleep(1)
        return False

    def call(self, method: str, **params: object) -> dict:
        self.msg_id += 1
        self.ws.send(
            json.dumps({"id": self.msg_id, "method": method, "params": params})
        )
        while True:
            reply = json.loads(self.ws.recv())
            if reply.get("id") == self.msg_id:
                return reply

    def evaluate(self, expression: str) -> str:
        reply = self.call("Runtime.evaluate", expression=expression, returnByValue=True)
        return str(reply.get("result", {}).get("result", {}).get("value"))

    def navigate(self, url: str) -> str:
        """Return the error text, or 'ok' once the page URL has settled."""
        self.call("Page.navigate", url="about:blank")
        time.sleep(0.5)
        error = self.call("Page.navigate", url=url)["result"].get("errorText")
        if error:
            return error
        for _ in range(30):
            time.sleep(1)
            if self.evaluate("location.href") != "about:blank":
                return "ok"
        return "timeout"

    def route_in_page(self, route: str) -> str:
        """Open an allowlisted page and route in-page.

        Returns "kept" when the document survived (the in-page move went
        unchallenged) or "reloaded" when something replaced it. A marker on
        window tells the two apart: Facebook's own script may rewrite the
        path on a logged-out page, so the path alone proves nothing.
        """
        if self.navigate("https://www.facebook.com/login/") != "ok":
            return "login page did not load"
        self.evaluate("window.__fbprobe = 1")
        self.evaluate(f"history.pushState({{}}, '', '{route}')")
        time.sleep(SETTLE_SECONDS)
        return "kept" if self.evaluate("window.__fbprobe") == "1" else "reloaded"

    def close(self) -> None:
        self.proc.kill()


def main() -> int:
    probe = Probe(sys.argv[1])
    failures = 0

    def check(label: str, got: str, ok: bool) -> None:
        nonlocal failures
        failures += not ok
        print(f"{'PASS' if ok else 'FAIL'}: {label} -> {got}")

    try:
        print(f"extension active: {probe.wait_for_extension()}")
        for url in ("https://www.facebook.com" + REEL, "https://www.facebook.com/"):
            got = probe.navigate(url)
            check(f"direct load {url} blocked", got, got == BLOCKED)
        for url in (
            "https://www.messenger.com/",
            "https://www.facebook.com/messages/t/1",
        ):
            got = probe.navigate(url)
            check(f"direct load {url} allowed", got, got == "ok")
        for route in (REEL, "/", "/watch/"):
            got = probe.route_in_page(route)
            check(f"in-page route to {route} rejected", got, got == "reloaded")
        got = probe.route_in_page("/messages/t/1")
        check("in-page route to /messages/t/1 kept", got, got == "kept")
    finally:
        probe.close()
    print(f"{'ALL PASS' if failures == 0 else str(failures) + ' FAILED'}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
