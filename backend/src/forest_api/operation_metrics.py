"""Bounded, payload-free request/query/write/transaction measurements."""

import logging
from collections import deque
from contextvars import ContextVar
from time import perf_counter

from sqlalchemy import event

current = ContextVar("forest_operation_metrics", default=None)
log = logging.getLogger("forest.metrics")


def instrument(engine):
    @event.listens_for(engine, "before_cursor_execute")
    def before(connection, cursor, statement, parameters, context, many):
        context._forest_started = perf_counter()

    @event.listens_for(engine, "after_cursor_execute")
    def after(connection, cursor, statement, parameters, context, many):
        sample = current.get()
        if sample is not None:
            sample["queries"] += 1
            sample["sqlMs"] += (perf_counter() - context._forest_started) * 1000
            if context.isinsert or context.isupdate or context.isdelete:
                sample["rowsWritten"] += max(0, cursor.rowcount)

    @event.listens_for(engine, "begin")
    def begin(connection):
        connection.info["forest_transaction_started"] = perf_counter()

    @event.listens_for(engine, "commit")
    @event.listens_for(engine, "rollback")
    def finish(connection):
        started = connection.info.pop("forest_transaction_started", None)
        sample = current.get()
        if sample is not None and started is not None:
            sample["transactionMs"] += (perf_counter() - started) * 1000


class OperationMetrics:
    def __init__(self, app, *, collector):
        self.app = app
        self.collector = collector

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or not self.collector.enabled:
            return await self.app(scope, receive, send)
        sample = dict(queries=0, rowsWritten=0, sqlMs=0.0, transactionMs=0.0, responseBytes=0)
        token = current.set(sample)
        started = perf_counter()

        async def measured(message):
            if message["type"] == "http.response.start":
                sample["status"] = message["status"]
            if message["type"] == "http.response.body":
                sample["responseBytes"] += len(message.get("body", b""))
            await send(message)

        try:
            await self.app(scope, receive, measured)
        finally:
            sample["requestMs"] = (perf_counter() - started) * 1000
            route = scope.get("route")
            sample["route"] = getattr(route, "path", "unmatched")
            sample["method"] = scope["method"]
            self.collector.samples.append(sample)
            log.info("operation %s", sample)
            current.reset(token)


class Collector:
    def __init__(self, *, enabled=False):
        self.enabled = enabled
        self.samples = deque(maxlen=128)
        if enabled:
            log.setLevel(logging.INFO)
            if not log.handlers:
                log.addHandler(logging.StreamHandler())
            log.propagate = False
