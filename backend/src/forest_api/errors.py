from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse


class ApiError(Exception):
    def __init__(self, status: int, code: str, message: str, details: dict | None = None):
        self.status = status
        self.code = code
        self.message = message
        self.details = details


class RequestRecovery(Exception):
    """Successful prior completion or obsolete control, never a fresh mutation."""

    def __init__(self, payload: dict):
        self.payload = payload


def install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(RequestRecovery)
    async def recovery_handler(request: Request, result: RequestRecovery) -> JSONResponse:
        return JSONResponse(status_code=200, content={"recovery": result.payload})

    @app.exception_handler(ApiError)
    async def api_error_handler(request: Request, error: ApiError) -> JSONResponse:
        payload = {"code": error.code, "message": error.message}
        if error.details is not None:
            payload["details"] = error.details
        return JSONResponse(
            status_code=error.status,
            content={"error": payload},
            headers={"WWW-Authenticate": "Bearer"} if error.status == 401 else None,
        )

    @app.exception_handler(RequestValidationError)
    async def validation_error_handler(
        request: Request, error: RequestValidationError
    ) -> JSONResponse:
        # Do not echo bodies/tokens/health inputs into diagnostics or logs.
        return JSONResponse(
            status_code=422,
            content={"error": {"code": "invalid_request", "message": "Invalid request fields"}},
        )
