"""Strong references to immutable definitions for one database transaction only."""


def definition(session, model, key):
    cache = session.info.setdefault("reference_definitions", {})
    identity = model, key
    if identity not in cache:
        value = session.get(model, key)
        # Do not negatively cache unpublished definitions: a caller may publish
        # and then use one within this transaction.
        if value is not None:
            cache[identity] = value
        return value
    return cache[identity]
