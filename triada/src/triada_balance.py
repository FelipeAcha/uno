#!/usr/bin/env python3
"""Minimal TRIADA balance calculator.

The input CSV must contain:
- start: ISO-8601 datetime
- end: ISO-8601 datetime
- domain: SELF, WORK, or RELATIONSHIPS
- evidence: MEASURED, ESTIMATED, or SELF_REPORTED
- activity_type: free text taxonomy value

Only example or locally generated files should be processed. Do not commit
personal production data to GitHub.
"""

from __future__ import annotations

import argparse
import csv
import json
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Iterable

DOMAINS = ("SELF", "WORK", "RELATIONSHIPS")
EVIDENCE_LEVELS = ("MEASURED", "ESTIMATED", "SELF_REPORTED")
SOFT_MIN_PERCENT = 18.0
SOFT_MAX_PERCENT = 48.0


class TriadaInputError(ValueError):
    """Raised when an activity row is invalid."""


@dataclass(frozen=True)
class Activity:
    start: datetime
    end: datetime
    domain: str
    evidence: str
    activity_type: str

    @property
    def minutes(self) -> float:
        return (self.end - self.start).total_seconds() / 60.0


def parse_datetime(value: str, field: str, row_number: int) -> datetime:
    try:
        return datetime.fromisoformat(value)
    except ValueError as exc:
        raise TriadaInputError(
            f"Row {row_number}: {field} must be an ISO-8601 datetime: {value!r}"
        ) from exc


def parse_activity(row: dict[str, str], row_number: int) -> Activity:
    missing = [
        field
        for field in ("start", "end", "domain", "evidence", "activity_type")
        if not row.get(field)
    ]
    if missing:
        raise TriadaInputError(
            f"Row {row_number}: missing required fields: {', '.join(missing)}"
        )

    start = parse_datetime(row["start"], "start", row_number)
    end = parse_datetime(row["end"], "end", row_number)
    if end <= start:
        raise TriadaInputError(f"Row {row_number}: end must be after start")

    domain = row["domain"].strip().upper()
    if domain not in DOMAINS:
        raise TriadaInputError(
            f"Row {row_number}: domain must be one of {', '.join(DOMAINS)}"
        )

    evidence = row["evidence"].strip().upper()
    if evidence not in EVIDENCE_LEVELS:
        raise TriadaInputError(
            f"Row {row_number}: evidence must be one of {', '.join(EVIDENCE_LEVELS)}"
        )

    return Activity(
        start=start,
        end=end,
        domain=domain,
        evidence=evidence,
        activity_type=row["activity_type"].strip(),
    )


def read_activities(path: Path) -> list[Activity]:
    if not path.exists():
        raise TriadaInputError(f"File not found: {path}")

    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None:
            raise TriadaInputError("CSV has no header")
        return [parse_activity(row, index) for index, row in enumerate(reader, 2)]


def calculate_balance(activities: Iterable[Activity]) -> dict[str, object]:
    minutes_by_domain: dict[str, float] = defaultdict(float)
    minutes_by_evidence: dict[str, float] = defaultdict(float)

    for activity in activities:
        minutes_by_domain[activity.domain] += activity.minutes
        minutes_by_evidence[activity.evidence] += activity.minutes

    total = sum(minutes_by_domain.values())
    percentages = {
        domain: (minutes_by_domain[domain] / total * 100.0 if total else 0.0)
        for domain in DOMAINS
    }

    alerts = []
    if total == 0:
        alerts.append("NO_DATA")
    else:
        for domain in DOMAINS:
            percent = percentages[domain]
            if percent < SOFT_MIN_PERCENT:
                alerts.append(f"{domain}_BELOW_SOFT_CORRIDOR")
            elif percent > SOFT_MAX_PERCENT:
                alerts.append(f"{domain}_ABOVE_SOFT_CORRIDOR")

    return {
        "total_minutes": round(total, 1),
        "minutes_by_domain": {
            domain: round(minutes_by_domain[domain], 1) for domain in DOMAINS
        },
        "percent_by_domain": {
            domain: round(percentages[domain], 1) for domain in DOMAINS
        },
        "minutes_by_evidence": {
            level: round(minutes_by_evidence[level], 1) for level in EVIDENCE_LEVELS
        },
        "soft_corridor_percent": {
            "minimum": SOFT_MIN_PERCENT,
            "maximum": SOFT_MAX_PERCENT,
        },
        "alerts": alerts,
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Calculate TRIADA time balance from an activity CSV."
    )
    parser.add_argument("csv_path", type=Path, help="Path to activity CSV")
    parser.add_argument(
        "--compact", action="store_true", help="Print compact JSON instead of indented JSON"
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        result = calculate_balance(read_activities(args.csv_path))
    except TriadaInputError as exc:
        print(f"TRIADA input error: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(result, ensure_ascii=False, indent=None if args.compact else 2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
