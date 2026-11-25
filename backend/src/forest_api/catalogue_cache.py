"""One bounded, process-local published catalogue; never caches account data."""

from threading import Lock
from time import monotonic


class CatalogueCache:
    def __init__(self):
        self.lock = Lock()
        self.entry = None

    def get(self, key):
        with self.lock:
            if self.entry is not None:
                saved_key, deadline, value = self.entry
                if saved_key == key and monotonic() < deadline:
                    return value.model_copy(deep=True)
        return None

    def put(self, key, value, seconds):
        if seconds > 0:
            with self.lock:
                self.entry = key, monotonic() + seconds, value.model_copy(deep=True)
