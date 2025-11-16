#!/usr/bin/env bash
set -euo pipefail

########################################################################
# Config
########################################################################

# List your .sum files here (relative to the directory where you run watch)
# Examples:
#   ./gcc/gcc.sum
#   ./g++/g++.sum
#   ./libstdc++-v3/testsuite/libstdc++.sum
SUM_FILES=(
  "./gcc/gcc.sum"
  "./g++/g++.sum"
)

# Approximate total number of tests across all suites (for "progress" vibes)
# Adjust this to taste (90k is a decent ballpark for full gcc+g++).
TOTAL_EXPECTED_TESTS=410265

########################################################################
# Helpers
########################################################################

count_kind() {
    local kind="$1" file="$2"
    if [[ -f "$file" ]]; then
        awk -v k="$kind" -F':' '$1 == k {c++} END {print c+0}' "$file"
    else
        echo 0
    fi
}

# Colors
c_reset=$'\033[0m'
c_green=$'\033[32m'
c_red=$'\033[31m'
c_yellow=$'\033[33m'
c_blue=$'\033[34m'
c_cyan=$'\033[36m'
c_magenta=$'\033[35m'

kinds=(PASS FAIL XPASS XFAIL UNSUPPORTED UNRESOLVED)

# Global totals
TOT_PASS=0
TOT_FAIL=0
TOT_XPASS=0
TOT_XFAIL=0
TOT_UNSUPPORTED=0
TOT_UNRESOLVED=0

########################################################################
# Main
########################################################################

clear

for f in "${SUM_FILES[@]}"; do
    if [[ ! -f "$f" ]]; then
        printf "${c_cyan}=== %s (not found) ===${c_reset}\n\n" "$f"
        continue
    fi

    printf "${c_cyan}=== %s ===${c_reset}\n" "$f"
    printf "KIND           COUNT\n"

    for kind in "${kinds[@]}"; do
        n=$(count_kind "$kind" "$f")
        case "$kind" in
            PASS)            color="$c_green" ;;
            FAIL|UNRESOLVED) color="$c_red" ;;
            XPASS|XFAIL)     color="$c_yellow" ;;
            UNSUPPORTED)     color="$c_blue" ;;
            *)               color="$c_reset" ;;
        esac
        printf "  %-12s ${color}%7d${c_reset}\n" "${kind}:" "$n"

        # Accumulate global totals
        case "$kind" in
            PASS)        TOT_PASS=$((TOT_PASS + n)) ;;
            FAIL)        TOT_FAIL=$((TOT_FAIL + n)) ;;
            XPASS)       TOT_XPASS=$((TOT_XPASS + n)) ;;
            XFAIL)       TOT_XFAIL=$((TOT_XFAIL + n)) ;;
            UNSUPPORTED) TOT_UNSUPPORTED=$((TOT_UNSUPPORTED + n)) ;;
            UNRESOLVED)  TOT_UNRESOLVED=$((TOT_UNRESOLVED + n)) ;;
        esac
    done

    echo
done

########################################################################
# Global summary
########################################################################

echo
printf "${c_magenta}=== TOTAL ACROSS ALL SUITES ===${c_reset}\n"
printf "KIND           COUNT\n"
printf "  %-12s ${c_green}%7d${c_reset}\n" "PASS:"        "$TOT_PASS"
printf "  %-12s ${c_red}%7d${c_reset}\n"   "FAIL:"        "$TOT_FAIL"
printf "  %-12s ${c_yellow}%7d${c_reset}\n" "XPASS:"      "$TOT_XPASS"
printf "  %-12s ${c_yellow}%7d${c_reset}\n" "XFAIL:"      "$TOT_XFAIL"
printf "  %-12s ${c_blue}%7d${c_reset}\n"  "UNSUPPORTED:" "$TOT_UNSUPPORTED"
printf "  %-12s ${c_red}%7d${c_reset}\n"   "UNRESOLVED:"  "$TOT_UNRESOLVED"

# "Executed tests" we care about for progress:
# PASS + FAIL + XPASS + XFAIL + UNRESOLVED (UNSUPPORTED usually means "skipped").
TOT_EXEC=$((TOT_PASS + TOT_FAIL + TOT_XPASS + TOT_XFAIL + TOT_UNRESOLVED))

# Progress bar
bar_len=40
percent=0
filled=0

if (( TOTAL_EXPECTED_TESTS > 0 )); then
    percent=$((TOT_EXEC * 100 / TOTAL_EXPECTED_TESTS))
    (( percent > 100 )) && percent=100
    filled=$((TOT_EXEC * bar_len / TOTAL_EXPECTED_TESTS))
    (( filled > bar_len )) && filled=$bar_len
fi

bar_filled=$(printf '%*s' "$filled" '' | tr ' ' '#')
bar_empty=$(printf '%*s' $((bar_len - filled)) '' | tr ' ' '.')
bar="${bar_filled}${bar_empty}"

printf "\nProgress (approx): [%s] %3d%%  (%d / %d counted tests)\n" \
       "$bar" "$percent" "$TOT_EXEC" "$TOTAL_EXPECTED_TESTS"
