#!/bin/sh

# Stateful GTACore data-plane watchdog. The caller owns the nominal sampling
# cadence and restart policy; actual CPU duty and suspicion duration use the
# monotonic elapsed time between samples.

# These globals are the sourced-file API consumed by docker-entrypoint.sh and
# the deterministic state tests.
# shellcheck disable=SC2034
GTACORE_WATCHDOG_PID=""
# shellcheck disable=SC2034
GTACORE_WATCHDOG_PROCESS_START=""
# shellcheck disable=SC2034
GTACORE_WATCHDOG_LAST_PROGRESS=""
# shellcheck disable=SC2034
GTACORE_WATCHDOG_SUSPECT_TID=""
# shellcheck disable=SC2034
GTACORE_WATCHDOG_SUSPECT_MILLIS=0
# shellcheck disable=SC2034
GTACORE_WATCHDOG_SUSPECT_SECS=0
# shellcheck disable=SC2034
GTACORE_WATCHDOG_WARNED=false
# shellcheck disable=SC2034
GTACORE_WATCHDOG_PREVIOUS_SAMPLE=""
# shellcheck disable=SC2034
GTACORE_WATCHDOG_LAST_SAMPLE_MILLIS=""
# shellcheck disable=SC2034
GTACORE_WATCHDOG_HOT_TID=""
# shellcheck disable=SC2034
GTACORE_WATCHDOG_HOT_PERMILLE=0

reset_gtacore_watchdog() {
    [ -n "$GTACORE_WATCHDOG_PREVIOUS_SAMPLE" ] \
        && rm -f "$GTACORE_WATCHDOG_PREVIOUS_SAMPLE"
    GTACORE_WATCHDOG_PID=""
    GTACORE_WATCHDOG_PROCESS_START=""
    GTACORE_WATCHDOG_LAST_PROGRESS=""
    GTACORE_WATCHDOG_SUSPECT_TID=""
    GTACORE_WATCHDOG_SUSPECT_MILLIS=0
    GTACORE_WATCHDOG_SUSPECT_SECS=0
    GTACORE_WATCHDOG_WARNED=false
    GTACORE_WATCHDOG_PREVIOUS_SAMPLE=""
    GTACORE_WATCHDOG_LAST_SAMPLE_MILLIS=""
    GTACORE_WATCHDOG_HOT_TID=""
    GTACORE_WATCHDOG_HOT_PERMILLE=0
}

gtacore_process_stat() {
    _watchdog_stat_pid="$1"
    _watchdog_proc_root=${GTAGOD_PROC_ROOT:-${GTACORE_WATCHDOG_PROC_ROOT:-/proc}}
    case "$_watchdog_stat_pid" in ''|*[!0-9]*|0) return 1 ;; esac
    awk '
        match($0, /\) [RSDTtZXxIWPK] /) {
            rest = substr($0, RSTART + 2)
            count = split(rest, fields, " ")
            if (count >= 20 && fields[20] ~ /^[0-9]+$/) {
                print fields[1], fields[20]
                found = 1
                exit
            }
        }
        END { if (!found) exit 1 }
    ' "$_watchdog_proc_root/$_watchdog_stat_pid/stat" 2>/dev/null
}

gtacore_process_identity() {
    _watchdog_identity_pid="$1"
    _watchdog_identity_stat=$(gtacore_process_stat "$_watchdog_identity_pid") || return 1
    set -- $_watchdog_identity_stat
    [ "$#" -eq 2 ] || return 1
    printf '%s:%s\n' "$_watchdog_identity_pid" "$2"
}

gtacore_process_identity_matches() {
    _watchdog_match_pid="$1"
    _watchdog_expected_identity="$2"
    [ -n "$_watchdog_expected_identity" ] || return 1
    _watchdog_current_identity=$(gtacore_process_identity "$_watchdog_match_pid") || return 1
    [ "$_watchdog_current_identity" = "$_watchdog_expected_identity" ]
}

gtacore_process_is_running() {
    _watchdog_running_pid="$1"
    _watchdog_running_identity="${2:-}"
    [ -n "$_watchdog_running_pid" ] && kill -0 "$_watchdog_running_pid" 2>/dev/null || return 1
    _watchdog_running_stat=$(gtacore_process_stat "$_watchdog_running_pid") || return 1
    set -- $_watchdog_running_stat
    [ "$#" -eq 2 ] || return 1
    case "$1" in Z|X|x|T|t) return 1 ;; esac
    if [ -n "$_watchdog_running_identity" ]; then
        [ "$_watchdog_running_identity" = "$_watchdog_running_pid:$2" ] || return 1
    fi
    return 0
}

gtacore_process_is_signalable() {
    _watchdog_signal_pid="$1"
    _watchdog_signal_identity="$2"
    [ -n "$_watchdog_signal_identity" ] || return 1
    [ -n "$_watchdog_signal_pid" ] && kill -0 "$_watchdog_signal_pid" 2>/dev/null || return 1
    _watchdog_signal_stat=$(gtacore_process_stat "$_watchdog_signal_pid") || return 1
    set -- $_watchdog_signal_stat
    [ "$#" -eq 2 ] || return 1
    [ "$_watchdog_signal_identity" = "$_watchdog_signal_pid:$2" ] || return 1
    case "$1" in Z|X|x) return 1 ;; esac
    return 0
}

gtacore_watchdog_now_millis() {
    case "${GTACORE_WATCHDOG_NOW_MILLIS:-}" in
        ''|*[!0-9]*) ;;
        *) printf '%s\n' "$GTACORE_WATCHDOG_NOW_MILLIS"; return 0 ;;
    esac
    _watchdog_proc_root=${GTACORE_WATCHDOG_PROC_ROOT:-/proc}
    awk '
        $1 ~ /^[0-9]+([.][0-9]+)?$/ {
            printf "%.0f\n", $1 * 1000
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$_watchdog_proc_root/uptime" 2>/dev/null
}

set_gtacore_watchdog_baseline() {
    _watchdog_baseline_pid="$1"
    _watchdog_baseline_start="$2"
    _watchdog_baseline_progress="$3"
    _watchdog_baseline_sample="$4"
    _watchdog_baseline_millis="$5"
    [ -n "$GTACORE_WATCHDOG_PREVIOUS_SAMPLE" ] \
        && [ "$GTACORE_WATCHDOG_PREVIOUS_SAMPLE" != "$_watchdog_baseline_sample" ] \
        && rm -f "$GTACORE_WATCHDOG_PREVIOUS_SAMPLE"
    GTACORE_WATCHDOG_PID=$_watchdog_baseline_pid
    GTACORE_WATCHDOG_PROCESS_START=$_watchdog_baseline_start
    GTACORE_WATCHDOG_LAST_PROGRESS=$_watchdog_baseline_progress
    GTACORE_WATCHDOG_SUSPECT_TID=""
    GTACORE_WATCHDOG_SUSPECT_MILLIS=0
    GTACORE_WATCHDOG_SUSPECT_SECS=0
    GTACORE_WATCHDOG_WARNED=false
    GTACORE_WATCHDOG_PREVIOUS_SAMPLE=$_watchdog_baseline_sample
    GTACORE_WATCHDOG_LAST_SAMPLE_MILLIS=$_watchdog_baseline_millis
    GTACORE_WATCHDOG_HOT_TID=""
    GTACORE_WATCHDOG_HOT_PERMILLE=0
}

capture_gtacore_thread_sample() {
    _watchdog_pid="$1"
    _watchdog_output="$2"
    _watchdog_proc_root=${GTACORE_WATCHDOG_PROC_ROOT:-/proc}
    _watchdog_task_dir="$_watchdog_proc_root/$_watchdog_pid/task"
    [ -d "$_watchdog_task_dir" ] || return 1

    # /proc/TID/stat field 2 (comm) may contain spaces. Locate the closing
    # ") STATE " marker, then utime/stime are fields 12/13 of the remainder.
    awk '
        match($0, /\) [RSDTtZXxIWPK] /) {
            tid = $1
            rest = substr($0, RSTART + 2)
            count = split(rest, fields, " ")
            if (count >= 13 && fields[12] ~ /^[0-9]+$/ && fields[13] ~ /^[0-9]+$/) {
                print tid, fields[12] + fields[13]
            }
        }
    ' "$_watchdog_task_dir"/[0-9]*/stat > "$_watchdog_output" 2>/dev/null || return 1
    [ -s "$_watchdog_output" ]
}

hottest_gtacore_thread_delta() {
    _watchdog_previous="$1"
    _watchdog_current="$2"
    awk '
        FILENAME == ARGV[1] { previous[$1] = $2; next }
        ($1 in previous) {
            delta = $2 - previous[$1]
            if (delta >= 0 && (hot_tid == "" || delta > hot_delta)) {
                hot_tid = $1
                hot_delta = delta
            }
        }
        END {
            if (hot_tid != "") print hot_tid, hot_delta
        }
    ' "$_watchdog_previous" "$_watchdog_current"
}

# Returns 2 only when a sustained spin is confirmed. All malformed or missing
# telemetry fails open and resets suspicion rather than restarting a live core.
evaluate_gtacore_watchdog() {
    _watchdog_pid="$1"
    _watchdog_progress="$2"
    _watchdog_elapsed_millis="$3"
    _watchdog_hot_tid="$4"
    _watchdog_hot_permille="$5"
    _watchdog_threshold=${GTACORE_WATCHDOG_CPU_PERCENT:-90}
    _watchdog_confirm=${GTACORE_WATCHDOG_CONFIRM_SECS:-300}
    _watchdog_warn=${GTACORE_WATCHDOG_WARN_SECS:-60}

    case "$_watchdog_pid" in ''|*[!0-9]*|0) reset_gtacore_watchdog; return 0 ;; esac
    case "$_watchdog_progress" in ''|*[!0-9]*) reset_gtacore_watchdog; return 0 ;; esac
    case "$_watchdog_elapsed_millis" in ''|*[!0-9]*|0) reset_gtacore_watchdog; return 0 ;; esac
    case "$_watchdog_hot_tid" in ''|*[!0-9]*|0) reset_gtacore_watchdog; return 0 ;; esac
    case "$_watchdog_hot_permille" in ''|*[!0-9]*) reset_gtacore_watchdog; return 0 ;; esac

    if [ "$GTACORE_WATCHDOG_PID" != "$_watchdog_pid" ]; then
        GTACORE_WATCHDOG_PID=$_watchdog_pid
        GTACORE_WATCHDOG_LAST_PROGRESS=$_watchdog_progress
        GTACORE_WATCHDOG_SUSPECT_TID=""
        GTACORE_WATCHDOG_SUSPECT_MILLIS=0
        GTACORE_WATCHDOG_SUSPECT_SECS=0
        GTACORE_WATCHDOG_WARNED=false
        return 0
    fi

    if [ "$GTACORE_WATCHDOG_LAST_PROGRESS" != "$_watchdog_progress" ]; then
        GTACORE_WATCHDOG_LAST_PROGRESS=$_watchdog_progress
        GTACORE_WATCHDOG_SUSPECT_TID=""
        GTACORE_WATCHDOG_SUSPECT_MILLIS=0
        GTACORE_WATCHDOG_SUSPECT_SECS=0
        GTACORE_WATCHDOG_WARNED=false
        return 0
    fi

    _watchdog_threshold_permille=$((_watchdog_threshold * 10))
    if [ "$_watchdog_hot_permille" -lt "$_watchdog_threshold_permille" ]; then
        GTACORE_WATCHDOG_SUSPECT_TID=""
        GTACORE_WATCHDOG_SUSPECT_MILLIS=0
        GTACORE_WATCHDOG_SUSPECT_SECS=0
        GTACORE_WATCHDOG_WARNED=false
        return 0
    fi

    if [ "$GTACORE_WATCHDOG_SUSPECT_TID" = "$_watchdog_hot_tid" ]; then
        GTACORE_WATCHDOG_SUSPECT_MILLIS=$((GTACORE_WATCHDOG_SUSPECT_MILLIS + _watchdog_elapsed_millis))
    else
        GTACORE_WATCHDOG_SUSPECT_TID=$_watchdog_hot_tid
        GTACORE_WATCHDOG_SUSPECT_MILLIS=$_watchdog_elapsed_millis
        GTACORE_WATCHDOG_WARNED=false
    fi
    GTACORE_WATCHDOG_SUSPECT_SECS=$((GTACORE_WATCHDOG_SUSPECT_MILLIS / 1000))
    GTACORE_WATCHDOG_HOT_TID=$_watchdog_hot_tid
    GTACORE_WATCHDOG_HOT_PERMILLE=$_watchdog_hot_permille

    if [ "$GTACORE_WATCHDOG_SUSPECT_MILLIS" -ge $((_watchdog_confirm * 1000)) ]; then
        return 2
    fi
    if [ "$GTACORE_WATCHDOG_SUSPECT_MILLIS" -ge $((_watchdog_warn * 1000)) ] \
        && [ "$GTACORE_WATCHDOG_WARNED" != true ]; then
        GTACORE_WATCHDOG_WARNED=true
        return 1
    fi
    return 0
}

check_gtacore_watchdog() {
    _watchdog_pid="$1"
    _watchdog_progress="$2"
    _watchdog_nominal_interval="$3"
    _watchdog_clock_ticks=${GTACORE_WATCHDOG_CLOCK_TICKS:-$(getconf CLK_TCK 2>/dev/null || echo 100)}
    case "$_watchdog_clock_ticks:$_watchdog_nominal_interval" in
        *[!0-9:]*|0:*|*:0) reset_gtacore_watchdog; return 0 ;;
    esac

    _watchdog_now_millis=$(gtacore_watchdog_now_millis) \
        || { reset_gtacore_watchdog; return 0; }
    _watchdog_process_identity=$(gtacore_process_identity "$_watchdog_pid") \
        || { reset_gtacore_watchdog; return 0; }
    _watchdog_process_start=${_watchdog_process_identity#*:}

    _watchdog_current=$(mktemp /tmp/gtagod-watchdog-current.XXXXXX) || return 0
    if ! capture_gtacore_thread_sample "$_watchdog_pid" "$_watchdog_current"; then
        rm -f "$_watchdog_current"
        reset_gtacore_watchdog
        return 0
    fi
    _watchdog_verified_identity=$(gtacore_process_identity "$_watchdog_pid") || {
        rm -f "$_watchdog_current"
        reset_gtacore_watchdog
        return 0
    }
    if [ "$_watchdog_verified_identity" != "$_watchdog_process_identity" ]; then
        rm -f "$_watchdog_current"
        reset_gtacore_watchdog
        return 0
    fi

    if [ "$GTACORE_WATCHDOG_PID" != "$_watchdog_pid" ] \
        || [ "$GTACORE_WATCHDOG_PROCESS_START" != "$_watchdog_process_start" ] \
        || [ -z "$GTACORE_WATCHDOG_PREVIOUS_SAMPLE" ] \
        || [ ! -f "$GTACORE_WATCHDOG_PREVIOUS_SAMPLE" ] \
        || [ -z "$GTACORE_WATCHDOG_LAST_SAMPLE_MILLIS" ]; then
        set_gtacore_watchdog_baseline \
            "$_watchdog_pid" "$_watchdog_process_start" "$_watchdog_progress" \
            "$_watchdog_current" "$_watchdog_now_millis"
        return 0
    fi

    _watchdog_elapsed_millis=$((_watchdog_now_millis - GTACORE_WATCHDOG_LAST_SAMPLE_MILLIS))
    if [ "$_watchdog_elapsed_millis" -le 0 ]; then
        set_gtacore_watchdog_baseline \
            "$_watchdog_pid" "$_watchdog_process_start" "$_watchdog_progress" \
            "$_watchdog_current" "$_watchdog_now_millis"
        return 0
    fi

    _watchdog_hot=$(hottest_gtacore_thread_delta \
        "$GTACORE_WATCHDOG_PREVIOUS_SAMPLE" "$_watchdog_current")
    rm -f "$GTACORE_WATCHDOG_PREVIOUS_SAMPLE"
    GTACORE_WATCHDOG_PREVIOUS_SAMPLE=$_watchdog_current
    GTACORE_WATCHDOG_LAST_SAMPLE_MILLIS=$_watchdog_now_millis
    set -- $_watchdog_hot
    [ "$#" -eq 2 ] || { reset_gtacore_watchdog; return 0; }
    _watchdog_denominator=$((_watchdog_clock_ticks * _watchdog_elapsed_millis))
    [ "$_watchdog_denominator" -gt 0 ] || { reset_gtacore_watchdog; return 0; }
    _watchdog_permille=$(($2 * 1000000 / _watchdog_denominator))

    evaluate_gtacore_watchdog \
        "$_watchdog_pid" "$_watchdog_progress" "$_watchdog_elapsed_millis" "$1" "$_watchdog_permille"
}
