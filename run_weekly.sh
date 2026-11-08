#!/bin/bash
# 이번 주 메뉴 수집에 성공할 때까지만 weekly_check.py를 실행한다.
# --last: 그날의 마지막 시도. 실패하면 파이를 끄고 다음 근무일에 다시 켠다.
cd "$(dirname "$0")" || exit 1

STAMP=.weekly_done
WEEK=$(date +%G-W%V)
TODAY=$(date +%F)

# holidays를 못 읽으면 공휴일이 아닌 것으로 본다.
is_holiday() {
    .venv/bin/python -c "import datetime,holidays,sys; sys.exit(0 if datetime.date.fromisoformat('$1') in holidays.KR() else 1)"
}

# $1부터 시작해 주말과 공휴일이 아닌 첫 날짜를 출력한다.
next_workday() {
    local day=$1
    while [ "$(date -d "$day" +%u)" -gt 5 ] || is_holiday "$day"; do
        day=$(date -d "$day +1 day" +%F)
    done
    echo "$day"
}

# $1 날짜 10:50에 켜지도록 RTC 알람을 맞추고 종료한다.
halt_until() {
    local alarm=/sys/class/rtc/rtc0/wakealarm
    local wake_in=$(( $(date -d "$1 10:50" +%s) - $(date +%s) ))

    # 알람을 못 맞춘 채 꺼지면 다시 켜지지 않으므로 그때는 종료하지 않는다.
    if echo 0 | sudo -n tee "$alarm" > /dev/null && echo "+$wake_in" | sudo -n tee "$alarm" > /dev/null; then
        echo "$(date '+%F %T') 라즈베리파이 종료: 다음 시작 $1 10:50"
        sudo -n /sbin/halt
    else
        echo "$(date '+%F %T') 알람 설정 실패: 종료하지 않음"
        exit 1
    fi
}

# 이번 주에 이미 성공했으면 종료
[ "$(cat "$STAMP" 2>/dev/null)" = "$WEEK" ] && exit 0

if is_holiday "$TODAY"; then
    echo "$(date '+%F %T') 공휴일: 건너뜀"
    exit 0
fi

if .venv/bin/python weekly_check.py; then
    echo "$(date '+%F %T') 1차 성공: 30분 뒤 재수집"

    # 메뉴를 작성하는 중이면 일부만 수집될 수 있어 한 번만 더 실행한다.
    sleep 1800
    if .venv/bin/python weekly_check.py; then
        echo "$(date '+%F %T') 재수집 성공"
    else
        echo "$(date '+%F %T') 재수집 실패: 1차 결과 유지"
    fi

    echo "$WEEK" > "$STAMP"
    halt_until "$(next_workday "$(date -d "$TODAY +$(( 8 - $(date +%u) )) days" +%F)")"
else
    echo "$(date '+%F %T') 실패 또는 미게시"
    if [ "$1" = "--last" ]; then
        halt_until "$(next_workday "$(date -d "$TODAY +1 day" +%F)")"
    fi
    exit 1
fi
