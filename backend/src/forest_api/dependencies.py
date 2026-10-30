from collections.abc import Iterator

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from forest_api.auth import Identity
from forest_api.errors import ApiError

bearer = HTTPBearer(auto_error=False)


def get_session(request: Request) -> Iterator[Session]:
    with request.app.state.database.sessions() as session:
        session.info["recovery_version"] = (
            1 if request.headers.get("X-Forest-Recovery") == "1" else 0
        )
        yield session


def get_identity(
    request: Request,
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
) -> Identity:
    if credentials is None or credentials.scheme.lower() != "bearer":
        raise ApiError(401, "authentication_required", "Bearer authentication required")
    return request.app.state.verifier.verify(credentials.credentials)
