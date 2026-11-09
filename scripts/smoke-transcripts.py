"""Bounded synthetic end-to-end check. Tokens stay in process memory."""

import argparse
import sys
from uuid import uuid4

import httpx


def check(condition, message):
    if not condition:
        raise RuntimeError(message)


def smoke(base_url):
    handle = "tx-smoke-" + uuid4().hex[:16]
    stream = "smoke-" + uuid4().hex
    path = f"/transcripts/{stream}/segments/0"
    body = {"revision": 1, "transcript": "Synthetic first partial.", "consent": True}
    with httpx.Client(base_url=base_url, timeout=45, follow_redirects=False) as client:
        def call(method, url, expected=200, **kwargs):
            response = client.request(method, url, **kwargs)
            check(response.status_code == expected, f"{method} {url}: expected {expected}, got {response.status_code}")
            return response.json()

        profile = call("PUT", "/me", expected=201, json={"handle": handle, "conference": "cnh"})
        client.headers["Authorization"] = "Bearer " + profile["token"]
        first = call("PUT", path, json=body)
        check(first["result"] == "created", "Initial write was not created")
        saved = call("GET", path)
        check(saved["transcript"] == body["transcript"] and not saved["finalized"], "Partial was not persisted")
        print("PASS: partial persisted before recording finalization")

        retry = call("PUT", path, json=body)
        check(retry["result"] == "unchanged", "Identical retry was not idempotent")
        final = body | {"revision": 2, "transcript": "Synthetic first recording, corrected.", "finalized": True}
        check(call("PUT", path, json=final)["result"] == "updated", "Final revision did not replace partial")
        call("PUT", path, expected=409, json=body)
        check(call("PUT", path, json=final)["result"] == "unchanged", "Final retry was not idempotent")
        print("PASS: replacement, finalization, retries and stale-revision protection")

        second = body | {"transcript": "Synthetic second recording.", "finalized": True}
        call("PUT", f"/transcripts/{stream}/segments/1", json=second)
        page = call("GET", f"/transcripts/{stream}?limit=1")
        check(page["next_after"] == 0 and len(page["segments"]) == 1, "First page incorrect")
        check(page["segments"][0]["transcript"] == final["transcript"], "Earlier recording changed")
        page = call("GET", f"/transcripts/{stream}?limit=1&after=0")
        check(page["next_after"] is None and page["segments"][0]["sequence"] == 1, "Second page incorrect")
        check(page["segments"][0]["transcript"] == second["transcript"], "Second recording missing")
        print("PASS: second recording appended and paginated without overwriting the first")

        del client.headers["Authorization"]
        call("GET", path, expected=401)
        call("PUT", path, expected=401, json=body)
        print("PASS: unauthenticated reads and writes rejected")
    print("PASS: realtime transcript database smoke check (two synthetic segments retained under expiry policy)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="https://grindset.cnh.radarhq.io")
    args = parser.parse_args()
    if not args.base_url.startswith("https://"):
        parser.error("Use an HTTPS API origin")
    try:
        smoke(args.base_url)
    except (httpx.HTTPError, RuntimeError, KeyError, ValueError) as problem:
        # Never print response bodies, tokens, or request headers.
        message = str(problem) if isinstance(problem, RuntimeError) else type(problem).__name__
        print("FAIL: " + message, file=sys.stderr)
        sys.exit(1)
