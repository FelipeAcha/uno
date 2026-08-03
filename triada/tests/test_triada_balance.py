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


def test_calculate_balance_and_alerts() -> None:
    activities = [
        Activity(dt("2026-08-03T08:00:00-05:00"), dt("2026-08-03T09:00:00-05:00"), "SELF", "MEASURED", "MEDITATION_RECOVERY"),
        Activity(dt("2026-08-03T09:00:00-05:00"), dt("2026-08-03T13:00:00-05:00"), "WORK", "MEASURED", "SOLO_DEEP_WORK"),
        Activity(dt("2026-08-03T18:00:00-05:00"), dt("2026-08-03T20:00:00-05:00"), "RELATIONSHIPS", "SELF_REPORTED", "FAMILY_FRIENDS"),
    ]

    result = calculate_balance(activities)

    assert result["total_minutes"] == 420.0
    assert result["percent_by_domain"] == {
        "SELF": 14.3,
        "WORK": 57.1,
        "RELATIONSHIPS": 28.6,
    }
    assert "SELF_BELOW_SOFT_CORRIDOR" in result["alerts"]
    assert "WORK_ABOVE_SOFT_CORRIDOR" in result["alerts"]


def test_parse_activity_rejects_unknown_domain() -> None:
    row = {
        "start": "2026-08-03T08:00:00-05:00",
        "end": "2026-08-03T09:00:00-05:00",
        "domain": "OTHER",
        "evidence": "MEASURED",
        "activity_type": "UNKNOWN",
    }

    try:
        parse_activity(row, 2)
    except TriadaInputError as exc:
        assert "domain must be one of" in str(exc)
    else:
        raise AssertionError("Expected TriadaInputError")
