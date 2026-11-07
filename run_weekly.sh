#!/bin/bash
# 이번 주 메뉴 수집에 성공할 때까지만 weekly_check.py를 실행한다.
cd "$(dirname "$0")" || exit 1

STAMP=.weekly_done
WEEK=$(date +%G-W%V)

# 이번 주에 이미 성공했으면 종료
[ "$(cat "$STAMP" 2>/dev/null)" = "$WEEK" ] && exit 0

# 공휴일이면 건너뜀 (holidays를 못 읽으면 평일로 보고 그대로 실행)
if .venv/bin/python -c "import datetime,holidays,sys; sys.exit(0 if datetime.date.today() in holidays.KR() else 1)"; then
    echo "$(date '+%F %T') 공휴일: 건너뜀"
    exit 0
fi

if .venv/bin/python weekly_check.py; then
    echo "$WEEK" > "$STAMP"
    echo "$(date '+%F %T') 성공"
else
    echo "$(date '+%F %T') 실패 또는 미게시"
    exit 1
fi
