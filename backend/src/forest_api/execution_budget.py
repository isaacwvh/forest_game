"""Cooperative deadlines plus database cancellation; never detach a running thread."""

import time
from contextlib import contextmanager
from contextvars import ContextVar
from dataclasses import dataclass


class BudgetExceeded(Exception):
    pass


@dataclass
class Budget:
    deadline: float
    committed_transactions: int = 0

    def remaining_ms(self):
        remaining = int((self.deadline - time.monotonic()) * 1000)
        if remaining <= 0:
            raise BudgetExceeded
        return remaining


current = ContextVar("forest_execution_budget", default=None)


def checkpoint():
    budget = current.get()
    if budget is not None:
        budget.remaining_ms()


@contextmanager
def execution_budget(seconds):
    budget = Budget(time.monotonic() + seconds)
    token = current.set(budget)
    try:
        yield budget
    finally:
        current.reset(token)


@contextmanager
def cleanup_budget():
    """Rollback/unlock must run even after a task's work budget expires."""
    token = current.set(None)
    try:
        yield
    finally:
        current.reset(token)
