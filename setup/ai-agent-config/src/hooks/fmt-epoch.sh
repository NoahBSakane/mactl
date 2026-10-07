#!/bin/bash
# fmt-epoch.sh <epoch> -> 2026-10-10(Sat)11:42:34+09:00   (Asia/Tokyo, weekday in English, offset with a colon)
# One format for every moment shown to the user (usage-limit resets, the /ofuro end time).
# LC_ALL=C keeps the weekday English under a Japanese locale; macOS date has no %:z, hence the reshaping.
e="${1:-}"; [ -n "$e" ] || exit 0
o="$(TZ=Asia/Tokyo date -r "$e" '+%z' 2>/dev/null)" || exit 0
printf '%s%s:%s\n' "$(LC_ALL=C TZ=Asia/Tokyo date -r "$e" '+%Y-%m-%d(%a)%H:%M:%S')" "${o%??}" "${o#???}"
