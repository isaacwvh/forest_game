"""One bounded, process-local published catalogue; never caches account data."""

from collections import OrderedDict
from copy import deepcopy
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


class PublishedDefinitionCache:
    """Contained in one database instance; keys identify published immutable rows."""

    def __init__(self, capacity=32):
        self.lock = Lock()
        self.entries = OrderedDict()
        self.capacity = capacity

    def get(self, key):
        with self.lock:
            entry = self.entries.get(key)
            if entry is not None and monotonic() < entry[0]:
                self.entries.move_to_end(key)
                return deepcopy(entry[1])
            self.entries.pop(key, None)
        return None

    def put(self, key, value, seconds):
        with self.lock:
            self.entries[key] = (monotonic() + seconds, deepcopy(value))
            self.entries.move_to_end(key)
            if len(self.entries) > self.capacity:
                self.entries.popitem(last=False)
