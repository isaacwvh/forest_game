from collections.abc import Iterator

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from forest_api.auth import Identity
from forest_api.errors import ApiError

bearer = HTTPBearer(auto_error=False)


def get_session(request: Request) -> Iterator[Session]:
    yield from request.app.state.database.session()


def get_identity(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> Identity:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise ApiError(401, "authentication_required", "Bearer authentication required")
    return request.app.state.verifier.verify(credentials.credentials)
