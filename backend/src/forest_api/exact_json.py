"""Exact JSON numbers for placement writes, preserving the normal typed OpenAPI body."""

import json
from decimal import Decimal, InvalidOperation

from fastapi import Request
from fastapi.routing import APIRoute

from forest_api.errors import ApiError

MAX_BODY_BYTES = 65536


def decimal_token(token: str) -> Decimal:
    if len(token) > 64:
        raise ValueError("Numeric token is too long")
    return Decimal(token)


def integer_token(token: str) -> int:
    if len(token) > 64:
        raise ValueError("Numeric token is too long")
    return int(token)


def invalid_constant(token: str):
    raise ValueError("Nonfinite JSON numbers are invalid")


def unique_object(pairs: list[tuple]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("Duplicate JSON field")
        result[key] = value
    return result


def parse_exact_json(body: bytes):
    # Parse outside FastAPI's body-reading try/except, which turns arbitrary
    # exceptions from Request.json() into a generic HTTP 400 response.
    try:
        return json.loads(
            body,
            parse_float=decimal_token,
            parse_int=integer_token,
            parse_constant=invalid_constant,
            object_pairs_hook=unique_object,
        )
    except (ValueError, UnicodeError, RecursionError, InvalidOperation) as exc:
        raise ApiError(422, "invalid_request", "Invalid request fields") from exc


class ExactJSONRequest(Request):
    def __init__(self, scope, receive, parsed_json):
        super().__init__(scope, receive)
        self.parsed_json = parsed_json

    async def json(self):
        return self.parsed_json


class ExactJSONRoute(APIRoute):
    def get_route_handler(self):
        handler = super().get_route_handler()

        async def exact_handler(request: Request):
            limit = 1_048_576 if request.url.path == "/v1/activity/sync" else MAX_BODY_BYTES
            size = 0
            chunks = []
            async for chunk in request.stream():
                size += len(chunk)
                if size > limit:
                    raise ApiError(413, "request_too_large", "Request body is too large")
                chunks.append(chunk)
            body = b"".join(chunks)
            parsed_json = parse_exact_json(body)
            sent = False

            async def receive():
                nonlocal sent
                if not sent:
                    sent = True
                    return {"type": "http.request", "body": body, "more_body": False}
                return await request.receive()

            return await handler(ExactJSONRequest(request.scope, receive, parsed_json))

        return exact_handler
