#!/usr/bin/env bash
# Korean patch self-check. Run from anywhere: test/korean.sh
# parse only — nothing is set, no timer is armed, no state is written.
set -uo pipefail
cd "$(dirname "$0")/.."
NAG=bin/nag

pass=0 fail=0

# Substring assertion: check <input> <expected-substring>
check() {
  local out
  out=$("$NAG" parse "$1" 2>/dev/null)
  if [[ $out == *"$2"* ]]; then
    ((pass += 1))
  else
    ((fail += 1))
    printf 'FAIL  %-26s expected *%s*\n      got: %s\n' "$1" "$2" "$out"
  fi
}

# Time-of-day independent clock assertion: "05:00" matches today or tomorrow.
recheck() {
  local out
  out=$("$NAG" parse "$1" 2>/dev/null)
  if [[ $out =~ $2 ]]; then
    ((pass += 1))
  else
    ((fail += 1))
    printf 'FAIL  %-26s expected re: %s\n      got: %s\n' "$1" "$2" "$out"
  fi
}


# Duration assertion with tolerance: check_in <input> <seconds-from-now>.
# format_remaining floors seconds, so a substring like "50m" flips to "49m"
# when a second passes between the two date calls; the epoch does not lie.
check_in() {
  local out at now delta want="$2"
  out=$("$NAG" parse "$1" 2>/dev/null)
  at=$(jq -r '.at // 0' <<<"$out")
  now=$(date +%s)
  delta=$((at - now))
  if ((delta <= want && delta > want - 5)); then
    ((pass += 1))
  else
    ((fail += 1))
    printf 'FAIL  %-26s expected ~%ss, got %ss\n' "$1" "$want" "$delta"
  fi
}

# --- hangul hours -----------------------------------------------------------
recheck "다섯시 아이 데리러"     '"atLabel":"(tomorrow )?05:00"'
recheck "여섯시 기상"            '"atLabel":"(tomorrow )?06:00"'
recheck "열두시 점심"            '"atLabel":"(tomorrow )?12:00"'
recheck "네시 반 회의"           '"atLabel":"(tomorrow )?04:30"'
recheck "다섯시반 커피"          '"atLabel":"(tomorrow )?05:30"'
recheck "다섯 시 반 커피"        '"atLabel":"(tomorrow )?05:30"'
recheck "다섯시삼십분 아이 데리러" '"atLabel":"(tomorrow )?05:30"'
recheck "다섯시십오분 알람"      '"atLabel":"(tomorrow )?05:15"'
recheck "오후 다섯시 퇴근"       '"atLabel":"(tomorrow )?17:00"'
recheck "오후다섯시 퇴근"        '"atLabel":"(tomorrow )?17:00"'
recheck "오전 9시 세탁"          '"atLabel":"(tomorrow )?09:00"'
recheck "오후 12시 점심"         '"atLabel":"(tomorrow )?12:00"'

# --- durations --------------------------------------------------------------
check_in "두시간 반 운동"   9000
check_in "한시간 스트레칭"  3600
check_in "반시간 쉬기"      1800
check_in "1시간 30분 전화"  5400
check_in "십분 산책"        600
check_in "십오분 정리"      900
check_in "이십오분 휴식"    1500
check_in "오십분 통화"      3000
check_in "십초 휴식"        10

# --- days -------------------------------------------------------------------
check_in "하루 뒤 복습"   86400
check_in "이틀 후 세탁"   172800
check_in "사흘 물주기"    259200
check_in "2주 뒤 보고서"  1209600

# --- relative days ----------------------------------------------------------
check "내일 9:00 치과"  '"atLabel":"tomorrow 09:00"'
check "내일9시 치과"    '"atLabel":"tomorrow 09:00"'
check "내일 열두시 마감" '"atLabel":"tomorrow 12:00"'

# --- messages ---------------------------------------------------------------
check "5분 차 마시기"     '"message":"차 마시기"'
check "5분 퇴근 후 맥주"  '"message":"퇴근 후 맥주"'
check "다섯시 아이 데리러" '"message":"아이 데리러"'
check "수요일18:15 하키"  '"message":"하키"'

# --- english regression -----------------------------------------------------
check_in "5m tea"                 300
check_in "1h30 call Paul"         5400
check "tomorrow 9:00 dentist"  '"atLabel":"tomorrow 09:00"'
check_in "5"                      300

# --- must be refused --------------------------------------------------------
check "hello world"     '"ok":false'
check "퇴근"            '"ok":false'
check "열시미 노력"     '"ok":false'
check "일시정지 해제"   '"ok":false'
check "다섯 명 점심"    '"ok":false'
check "삼겹살 먹기"     '"ok":false'

echo
echo "pass: $pass  fail: $fail"
((fail == 0))
