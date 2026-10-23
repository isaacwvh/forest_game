from sqlalchemy import func, select


def request_clock(request, session):
    injected = request.app.state.clock
    return (
        injected if injected is not None else lambda: session.scalar(select(func.clock_timestamp()))
    )
