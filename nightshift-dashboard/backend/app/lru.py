"""A small thread-safe LRU dict, so per-moment caches cannot grow forever during a long replay."""

import threading
from collections import OrderedDict


class LRU:
    def __init__(self, maxsize: int = 256):
        self.maxsize = maxsize
        self._d: OrderedDict = OrderedDict()
        self._lock = threading.Lock()

    def get(self, key, default=None):
        with self._lock:
            if key not in self._d:
                return default
            self._d.move_to_end(key)
            return self._d[key]

    def __setitem__(self, key, value):
        with self._lock:
            self._d[key] = value
            self._d.move_to_end(key)
            while len(self._d) > self.maxsize:
                self._d.popitem(last=False)

    def __contains__(self, key):
        with self._lock:
            return key in self._d

    def __len__(self):
        with self._lock:
            return len(self._d)

    def clear(self):
        with self._lock:
            self._d.clear()
