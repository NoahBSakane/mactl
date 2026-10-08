#!/usr/bin/env python3
"""When does a usage limit lift?   stdin: a CLI's error text   stdout: unix epoch, or nothing.

Understands what the agent CLIs print: an ISO date-time, `Oct 10th, 2026 11:42 AM`, a bare time
(`try again at 11:42 AM`, `resets 3pm (Asia/Tokyo)`: the next such time), a relative wait
(`in 2 hours 15 minutes`, `retry after 90s`) and a unix epoch (`resets_at: 1791600154`).
Only a moment in the future, at most 14 days away, is believed. Any problem prints nothing: the
caller falls back to a fixed wait.   `limit-reset.py --now <epoch>` fixes the clock (tests).
`limit-reset.py --is-limit`: exit 0 when the text reads like a usage/rate-limit refusal (not just a mention of a quota), else 1.
"""
import re
import sys
from datetime import datetime, timedelta, timezone

MONTHS = {m: i + 1 for i, m in enumerate("jan feb mar apr may jun jul aug sep oct nov dec".split())}
UNIT = {"s": 1, "sec": 1, "second": 1, "m": 60, "min": 60, "minute": 60, "h": 3600, "hr": 3600,
        "hour": 3600, "d": 86400, "day": 86400}


def tzinfo(text):
    m = re.search(r"\(([A-Za-z]+/[A-Za-z_]+)\)", text)
    if m:
        try:
            from zoneinfo import ZoneInfo
            return ZoneInfo(m.group(1))
        except Exception:  # noqa: BLE001
            pass
    return None


def hour24(h, ampm):
    h = int(h)
    if ampm:
        h = h % 12 + (12 if ampm.lower() == "pm" else 0)
    return h


def candidates(text, now):
    tz = tzinfo(text)
    local = lambda *a: datetime(*a, tzinfo=tz).timestamp() if tz else datetime(*a).timestamp()  # noqa: E731
    for m in re.finditer(r"(?:reset\w*|retry[-_ ]after|try again)\D{0,24}?(\d{10})\b", text, re.I):
        yield float(m.group(1))
    for m in re.finditer(r"(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?", text, re.I):
        y, mo, d, h, mi, s, ap = m.groups()
        yield local(int(y), int(mo), int(d), hour24(h, ap), int(mi), int(s or 0))
    for m in re.finditer(r"\b([A-Za-z]{3})[a-z]*\.? (\d{1,2})(?:st|nd|rd|th)?,?(?: (\d{4}),?)?(?: at)? (\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?",
                         text, re.I):
        mon, d, y, h, mi, s, ap = m.groups()
        if mon.lower()[:3] not in MONTHS:
            continue
        year = int(y) if y else datetime.fromtimestamp(now).year
        t = local(year, MONTHS[mon.lower()[:3]], int(d), hour24(h, ap), int(mi), int(s or 0))
        if not y and t < now:
            t = local(year + 1, MONTHS[mon.lower()[:3]], int(d), hour24(h, ap), int(mi), int(s or 0))
        yield t
    for m in re.finditer(r"(?:\bin|after|retry[-_ ]after:?)\s+((?:\d+(?:\.\d+)?\s*(?:days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)\b[\s,and]*)+)",
                         text, re.I):
        secs = sum(float(n) * UNIT[u.lower().rstrip("s") if u.lower() not in UNIT else u.lower()]
                   for n, u in re.findall(r"(\d+(?:\.\d+)?)\s*([A-Za-z]+)", m.group(1)) if (u.lower().rstrip("s") in UNIT or u.lower() in UNIT))
        if secs:
            yield now + secs
    for m in re.finditer(r"(?:\bat|resets?|until|after)\s+(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?\s*(am|pm)\b", text, re.I):
        h, mi, s, ap = m.groups()
        base = datetime.fromtimestamp(now, tz) if tz else datetime.fromtimestamp(now)
        t = base.replace(hour=hour24(h, ap), minute=int(mi or 0), second=int(s or 0), microsecond=0)
        if t.timestamp() <= now:
            t += timedelta(days=1)
        yield t.timestamp()


# the shapes of a refusal, not the words that merely mention a limit (a quota, a rate limit, "resets at")
LIMIT_TEXT = re.compile(
    r"hit your .{0,30}limit"                                              # You've hit your usage limit
    r"|(?:usage|rate|token|request)s? limit (?:has been |was )?(?:reached|exceeded|hit)"
    r"|exceeded your .{0,30}(?:quota|limit)"
    r"|quota (?:has been |was )?(?:reached|exhausted)"                      # Individual quota reached
    r"|RESOURCE_EXHAUSTED"
    r"|\b429\b.{0,40}too many requests|too many requests.{0,40}\b429\b",
    re.I | re.S)


def main():
    args = sys.argv[1:]
    if args[:1] == ["--is-limit"]:
        sys.exit(0 if LIMIT_TEXT.search(sys.stdin.read()[:8000]) else 1)
    now = float(args[1]) if len(args) >= 2 and args[0] == "--now" else datetime.now(timezone.utc).timestamp()
    try:
        text = sys.stdin.read()[:8000]
        for t in candidates(text, now):
            if now < t <= now + 14 * 86400:
                print(int(t))
                return
    except Exception:  # noqa: BLE001
        pass


if __name__ == "__main__":
    main()
