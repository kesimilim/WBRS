"""Exact read schedule branches; source local time never becomes guessed UTC."""
from imported_meeting_review import _scheduled_local, _sql_stamp
from runtime_mutations import RuntimeUnavailable


def read_schedule(local, starts_at):
    """Return the original local string or canonical SQL UTC6Z, exclusively.

    Native create validation remains its separate strict16 contract. Imported
    source timestamp normalization is owned by _schedule, never this wire check.
    """
    try:
        if (local is None) == (starts_at is None):
            raise RuntimeUnavailable()
        if starts_at is not None:
            if type(starts_at) is not str or _sql_stamp(starts_at) != starts_at:
                raise RuntimeUnavailable()
            return None, starts_at
        if type(local) is not str or _scheduled_local(local) != local:
            raise RuntimeUnavailable()
        return local, None
    except Exception:
        raise RuntimeUnavailable() from None
