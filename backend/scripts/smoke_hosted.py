"""Bounded HTTP acceptance. Uses real bearer tokens; never provisions or mutates accounts."""

import argparse
import json
import os
import time
import urllib.error
import urllib.request
from urllib.parse import urlsplit
from uuid import UUID

CAPABILITIES = {
    "X-Forest-Recovery": "1",
    "X-Forest-Woodland": "1",
    "X-Forest-Discovery": "2",
    "X-Forest-Milestones": "1",
    "X-Forest-Expeditions": "1",
    "X-Forest-Items": "1",
    "X-Forest-Item-Commerce": "1",
    "X-Forest-Item-Rotations": "1",
}


class NoRedirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def target_url(value):
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise ValueError("Use an HTTPS service origin without a path or credentials")
    return value.rstrip("/")


def get(base, path, token=None):
    headers = {"Accept": "application/json", **CAPABILITIES}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(base + path, headers=headers, method="GET")
    opener = urllib.request.build_opener(NoRedirects())
    try:
        response = opener.open(request, timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    with response:
        data = response.read(4 * 1024 * 1024 + 1)
        if len(data) > 4 * 1024 * 1024:
            raise ValueError("Smoke response exceeds its bound")
        return response.code, json.loads(data)


def run(
    base,
    *,
    mode="authenticated",
    token=None,
    expected_user=None,
    second_token=None,
    second_user=None,
    request=get,
):
    checks = []
    for path, expected in (("/health/live", "ok"), ("/health/ready", "ready")):
        for attempt in range(5):
            try:
                status, body = request(base, path)
                if status == 200 and body.get("status") == expected:
                    break
            except (OSError, ValueError):
                pass
            if attempt == 4:
                raise ValueError("Health acceptance failed")
            time.sleep(1)
        checks.append(path)
    status, body = request(base, "/v1/me")
    if mode == "maintenance":
        if status != 503 or body.get("error", {}).get("code") != "maintenance":
            raise ValueError("Maintenance gate did not reject gameplay")
        return {"status": "passed", "mode": mode, "checks": checks + ["maintenance"]}
    if status != 401:
        raise ValueError("Missing bearer was not rejected")
    if request(base, "/v1/me", "invalid-smoke-token")[0] != 401:
        raise ValueError("Invalid bearer was not rejected")
    checks += ["missing-bearer", "invalid-bearer"]
    if mode == "authenticated":
        if not token or not expected_user:
            raise ValueError("A real access token and expected game user UUID are required")
        UUID(expected_user)
        if bool(second_token) != bool(second_user):
            raise ValueError("Second token and expected UUID must be provided together")
        if second_user and second_user == expected_user:
            raise ValueError("Isolation acceptance requires two different game users")
        for credential, owner in ((token, expected_user), (second_token, second_user)):
            if not credential:
                continue
            status, profile = request(base, "/v1/me", credential)
            if status != 200 or profile.get("userId") != owner:
                raise ValueError("Authenticated profile does not match its expected game user")
            for path in ("/v1/catalog", "/v1/me/inventory?limit=1"):
                status, body = request(base, path, credential)
                if status != 200 or not isinstance(body, dict):
                    raise ValueError("Authenticated read failed")
            checks += ["verified-profile", "catalogue", "inventory"]
    return {"status": "passed", "mode": mode, "checks": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, type=target_url)
    parser.add_argument(
        "--mode",
        choices=["authenticated", "unauthenticated", "maintenance"],
        default="authenticated",
    )
    parser.add_argument("--expected-user-id")
    parser.add_argument("--second-user-id")
    args = parser.parse_args()
    try:
        print(
            json.dumps(
                run(
                    args.url,
                    mode=args.mode,
                    token=os.environ.get("FOREST_SMOKE_ACCESS_TOKEN"),
                    expected_user=args.expected_user_id,
                    second_token=os.environ.get("FOREST_SMOKE_SECOND_ACCESS_TOKEN"),
                    second_user=args.second_user_id,
                )
            )
        )
    except Exception as error:
        print(json.dumps({"status": "failed", "kind": type(error).__name__}))
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
