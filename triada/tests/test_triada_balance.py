from __future__ import annotations

import importlib.util
import sys
from datetime import datetime
from pathlib import Path

MODULE_PATH = Path(__file__).parents[1] / "src" / "triada_balance.py"
SPEC = importlib.util.spec_from_file_location("triada_balance", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

Activity = MODULE.Activity
TriadaInputError = MODULE.TriadaInputError
calculate_balance = MODULE.calculate_balance
parse_activity = MODULE.parse_activity


def dt(value: str) -> datetime:
    return datetime.fromisoformat(value)


def test_non_allocable_sleep_does_not_distort_balance() -> None:
    activities = [
        Activity(dt("2026-08-03T00:00:00-05:00"), dt("2026-08-03T08:00:00-05:00"), "SELF", "MEASURED", "SLEEP", "NON_ALLOCABLE"),
        Activity(dt("2026-08-03T08:00:00-05:00"), dt("2026-08-03T09:00:00-05:00"), "SELF", "MEASURED", "MEDITATION_RECOVERY", "ALLOCABLE"),
        Activity(dt("2026-08-03T09:00:00-05:00"), dt("2026-08-03T13:00:00-05:00"), "WORK", "MEASURED", "SOLO_DEEP_WORK", "ALLOCABLE"),
        Activity(dt("2026-08-03T18:00:00-05:00"), dt("2026-08-03T20:00:00-05:00"), "RELATIONSHIPS", "SELF_REPORTED", "FAMILY_FRIENDS", "ALLOCABLE"),
    ]

    result = calculate_balance(activities)

    assert result["tracked_minutes"] == 900.0
    assert result["allocable_minutes"] == 420.0
    assert result["non_allocable_minutes"] == 480.0
    assert result["percent_by_domain"] == {
        "SELF": 14.3,
        "WORK": 57.1,
        "RELATIONSHIPS": 28.6,
    }
    assert "SELF_BELOW_SOFT_CORRIDOR" in result["alerts"]
    assert "WORK_ABOVE_SOFT_CORRIDOR" in result["alerts"]


def test_parse_activity_rejects_unknown_scope() -> None:
    row = {
        "start": "2026-08-03T08:00:00-05:00",
        "end": "2026-08-03T09:00:00-05:00",
        "domain": "SELF",
        "evidence": "MEASURED",
        "activity_type": "SLEEP",
        "allocation_scope": "OTHER",
    }

    try:
        parse_activity(row, 2)
    except TriadaInputError as exc:
        assert "allocation_scope must be one of" in str(exc)
    else:
        raise AssertionError("Expected TriadaInputError")


def test_no_allocable_data_is_explicit() -> None:
    result = calculate_balance([
        Activity(dt("2026-08-03T00:00:00-05:00"), dt("2026-08-03T08:00:00-05:00"), "SELF", "MEASURED", "SLEEP", "NON_ALLOCABLE")
    ])
    assert result["allocable_minutes"] == 0.0
    assert result["alerts"] == ["NO_ALLOCABLE_DATA"]
