#!/bin/bash
# Frozen AC-11 idle-resource measurement harness.
# Usage: measure-idle.sh PID EVIDENCE_DIRECTORY ARTIFACT_PATH
set -euo pipefail
IFS=$'\n\t'
export LC_ALL=C

usage() {
  printf 'Usage: %s PID EVIDENCE_DIRECTORY ARTIFACT_PATH\n' "${0##*/}" >&2
}

if (( $# != 3 )); then
  usage
  exit 64
fi

PID="$1"
EVIDENCE_DIR="$2"
ARTIFACT_PATH="$3"

if [[ ! "$PID" =~ ^[1-9][0-9]*$ ]]; then
  printf 'FAIL: PID must be an explicit positive decimal process ID.\n' >&2
  exit 64
fi

if [[ ! -d "$EVIDENCE_DIR" ]]; then
  if ! /bin/mkdir -p "$EVIDENCE_DIR"; then
    printf 'FAIL: cannot create evidence directory: %s\n' "$EVIDENCE_DIR" >&2
    exit 1
  fi
fi
if ! EVIDENCE_DIR="$(CDPATH= cd -- "$EVIDENCE_DIR" && pwd -P)"; then
  printf 'FAIL: evidence directory is not accessible: %s\n' "$2" >&2
  exit 1
fi

readonly SAMPLES_FILE="$EVIDENCE_DIR/samples.csv"
readonly SUMMARY_FILE="$EVIDENCE_DIR/summary.txt"
readonly HOST_FILE="$EVIDENCE_DIR/host-facts.txt"
readonly ARTIFACT_FILE="$EVIDENCE_DIR/artifact-facts.txt"
readonly EXPECTED_ROWS=361
readonly EXPECTED_INTERVALS=360
readonly INTERVAL_SECONDS=5
readonly DRIFT_TOLERANCE_SECONDS=1
readonly MIN_INTERVAL_NS=$(( (INTERVAL_SECONDS - DRIFT_TOLERANCE_SECONDS) * 1000000000 ))
readonly MAX_INTERVAL_NS=$(( (INTERVAL_SECONDS + DRIFT_TOLERANCE_SECONDS) * 1000000000 ))

for evidence_file in "$SAMPLES_FILE" "$SUMMARY_FILE" "$HOST_FILE" "$ARTIFACT_FILE"; do
  if [[ -e "$evidence_file" || -L "$evidence_file" ]]; then
    printf 'FAIL: evidence file already exists; use a new evidence directory: %s\n' "$evidence_file" >&2
    exit 1
  fi
done

STATUS=FAIL
FAILURE_REASON='measurement did not complete'
SAMPLE_COUNT=0
INTERVAL_COUNT=0
DRIFT_COUNT=0
INITIAL_MONO_NS=''
FINAL_MONO_NS=''
INITIAL_CPU_SECONDS=''
FINAL_CPU_SECONDS=''
INITIAL_PROCESS_START=''
PREVIOUS_MONO_NS=''
PREVIOUS_ELAPSED_SECONDS=''
CPU_PERCENT='not computed'
RSS_MEAN_KIB='not computed'
RSS_MAX_KIB='not computed'
DRIFT_PERCENT='not computed'
GATE_CPU='not evaluated'
GATE_RSS='not evaluated'
GATE_DRIFT='not evaluated'
GATE_ROWS='not evaluated'
ARTIFACT_FACTS_COMPLETE=false
MEASUREMENT_START_WALL_UTC='not recorded'

write_summary() {
  local exit_code="$1"
  local end_wall_utc='unavailable'
  end_wall_utc="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" || end_wall_utc='unavailable'
  {
    printf 'recipe=AC-11 frozen idle-resource recipe\n'
    printf 'status=%s\n' "$STATUS"
    printf 'exit_code=%s\n' "$exit_code"
    printf 'failure_reason=%s\n' "$FAILURE_REASON"
    printf 'pid=%s\n' "$PID"
    printf 'evidence_directory=%s\n' "$EVIDENCE_DIR"
    printf 'raw_csv=%s\n' "$SAMPLES_FILE"
    printf 'host_facts=%s\n' "$HOST_FILE"
    printf 'artifact_facts=%s\n' "$ARTIFACT_FILE"
    printf 'measurement_start_wall_utc=%s\n' "$MEASUREMENT_START_WALL_UTC"
    printf 'measurement_end_wall_utc=%s\n' "$end_wall_utc"
    printf 'sample_interval_seconds=%d\n' "$INTERVAL_SECONDS"
    printf 'baseline_rows=1\n'
    printf 'interval_rows_expected=%d\n' "$EXPECTED_INTERVALS"
    printf 'rows_expected=%d\n' "$EXPECTED_ROWS"
    printf 'rows_observed=%d\n' "$SAMPLE_COUNT"
    printf 'intervals_observed=%d\n' "$INTERVAL_COUNT"
    printf 'interval_drift_over_1s=%d\n' "$DRIFT_COUNT"
    printf 'interval_drift_limit_percent=1.00\n'
    printf 'interval_drift_tolerance_seconds=%d\n' "$DRIFT_TOLERANCE_SECONDS"
    printf 'interval_drift_percent=%s\n' "$DRIFT_PERCENT"
    printf 'cpu_metric=100*(final_cpu_seconds-initial_cpu_seconds)/((final_monotonic_ns-initial_monotonic_ns)/1e9)\n'
    printf 'initial_monotonic_ns=%s\n' "${INITIAL_MONO_NS:-not recorded}"
    printf 'final_monotonic_ns=%s\n' "${FINAL_MONO_NS:-not recorded}"
    printf 'initial_cpu_seconds=%s\n' "${INITIAL_CPU_SECONDS:-not recorded}"
    printf 'final_cpu_seconds=%s\n' "${FINAL_CPU_SECONDS:-not recorded}"
    printf 'process_start=%s\n' "${INITIAL_PROCESS_START:-not recorded}"
    printf 'cpu_one_core_percent=%s\n' "$CPU_PERCENT"
    printf 'rss_mean_kib=%s\n' "$RSS_MEAN_KIB"
    printf 'rss_max_kib=%s\n' "$RSS_MAX_KIB"
    printf 'cpu_gate=cpu_one_core_percent < 1.00 (%s)\n' "$GATE_CPU"
    printf 'rss_gate=rss_max_kib < 102400 (%s)\n' "$GATE_RSS"
    printf 'drift_gate=intervals_over_1s <= 1%% (%s)\n' "$GATE_DRIFT"
    printf 'row_gate=361_rows_and_360_intervals (%s)\n' "$GATE_ROWS"
    printf 'artifact_facts_complete=%s\n' "$ARTIFACT_FACTS_COMPLETE"
    printf 'notarization_evidence=not performed by this numeric sampler; verify separately\n'
    printf 'operator_prerequisites=all five Providers enabled and loaded once; normal five-minute schedule; detail closed; no manual refresh/input; warm-up completed\n'
    printf 'provider_terminal_state=not inferred by this numeric sampler; attach operator evidence\n'
    printf 'reference_host_validation=review retained host facts against the frozen physical-host requirements\n'
  } >"$SUMMARY_FILE"
}

on_exit() {
  local exit_code="$?"
  set +e
  write_summary "$exit_code"
  return "$exit_code"
}
trap on_exit EXIT

abort() {
  FAILURE_REASON="$1"
  STATUS=FAIL
  printf 'AC-11 measurement: FAIL: %s\n' "$FAILURE_REASON" >&2
  exit 1
}

monotonic_ns() {
  if [[ -x /usr/bin/python3 ]]; then
    /usr/bin/python3 -c 'import time; print(time.monotonic_ns())'
    return
  fi
  if [[ -x /usr/bin/perl ]]; then
    /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
      -e 'printf "%.0f\n", clock_gettime(CLOCK_MONOTONIC) * 1000000000'
    return
  fi
  return 1
}

parse_duration_seconds() {
  local raw="$1"
  /usr/bin/awk -v raw="$raw" '
    BEGIN {
      if (raw == "") exit 2
      dash = index(raw, "-")
      days = 0
      if (dash > 0) {
        days = substr(raw, 1, dash - 1)
        raw = substr(raw, dash + 1)
      }
      if (days !~ /^[0-9]+$/ || raw == "") exit 2
      count = split(raw, part, ":")
      if (count == 3) {
        hours = part[1]
        minutes = part[2]
        seconds = part[3]
      } else if (count == 2) {
        hours = 0
        minutes = part[1]
        seconds = part[2]
      } else if (count == 1) {
        hours = 0
        minutes = 0
        seconds = part[1]
      } else {
        exit 2
      }
      if (hours !~ /^[0-9]+$/ || minutes !~ /^[0-9]+$/ || seconds !~ /^[0-9]+([.][0-9]+)?$/) exit 2
      printf "%.6f\n", (days * 86400) + (hours * 3600) + (minutes * 60) + seconds
    }
  '
}

OBSERVED_PID=''
OBSERVED_START=''
RAW_CPU=''
RAW_RSS=''
RAW_ELAPSED=''
OBSERVED_STATE=''
OBSERVED_CPU_SECONDS=''
OBSERVED_ELAPSED_SECONDS=''
OBSERVED_RSS_KIB=''

read_ps_sample() {
  local ps_row=''
  if ! ps_row="$(/bin/ps -p "$PID" -o pid= -o lstart= -o cputime= -o rss= -o etime= -o state= | /usr/bin/awk '
    NF {
      rows++
      if (rows == 1) {
        if (NF < 10) exit 2
        printf "%s\t%s %s %s %s %s\t%s\t%s\t%s\t%s\n", \
          $1, $2, $3, $4, $5, $6, $(NF - 3), $(NF - 2), $(NF - 1), $NF
      }
    }
    END {
      if (rows != 1) exit 3
    }
  ')"; then
    return 1
  fi

  IFS=$'\t' read -r OBSERVED_PID OBSERVED_START RAW_CPU RAW_RSS RAW_ELAPSED OBSERVED_STATE <<<"$ps_row"
  [[ "$OBSERVED_PID" == "$PID" ]] || return 2
  [[ "$RAW_RSS" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$OBSERVED_STATE" ]] || return 1
  [[ -n "$OBSERVED_START" ]] || return 1
  if [[ -n "$INITIAL_PROCESS_START" && "$OBSERVED_START" != "$INITIAL_PROCESS_START" ]]; then
    return 2
  fi
  case "$OBSERVED_STATE" in
    Z*) return 2 ;;
  esac
  if ! OBSERVED_CPU_SECONDS="$(parse_duration_seconds "$RAW_CPU")"; then
    return 1
  fi
  if ! OBSERVED_ELAPSED_SECONDS="$(parse_duration_seconds "$RAW_ELAPSED")"; then
    return 1
  fi
  OBSERVED_RSS_KIB="$RAW_RSS"
  if [[ -n "$PREVIOUS_ELAPSED_SECONDS" ]]; then
    if ! /usr/bin/awk -v previous="$PREVIOUS_ELAPSED_SECONDS" -v current="$OBSERVED_ELAPSED_SECONDS" \
      'BEGIN { exit !(current >= previous) }'; then
      return 2
    fi
  fi
  return 0
}

sample_process() {
  local sample_index="$1"
  local sample_status=0
  local sample_mono_ns=''
  local interval_ns=0

  if read_ps_sample; then
    :
  else
    sample_status=$?
    return "$sample_status"
  fi
  if ! sample_mono_ns="$(monotonic_ns)"; then
    return 1
  fi
  [[ "$sample_mono_ns" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "$PREVIOUS_MONO_NS" ]]; then
    if (( sample_mono_ns <= PREVIOUS_MONO_NS )); then
      return 2
    fi
    interval_ns=$((sample_mono_ns - PREVIOUS_MONO_NS))
    INTERVAL_COUNT=$((INTERVAL_COUNT + 1))
    if (( interval_ns < MIN_INTERVAL_NS || interval_ns > MAX_INTERVAL_NS )); then
      DRIFT_COUNT=$((DRIFT_COUNT + 1))
    fi
  else
    INITIAL_MONO_NS="$sample_mono_ns"
    INITIAL_CPU_SECONDS="$OBSERVED_CPU_SECONDS"
    INITIAL_PROCESS_START="$OBSERVED_START"
  fi

  printf '%d,%s,%s,%s,%s,%s,%s\n' \
    "$sample_index" "$OBSERVED_PID" "$sample_mono_ns" "$OBSERVED_CPU_SECONDS" \
    "$OBSERVED_RSS_KIB" "$OBSERVED_ELAPSED_SECONDS" "$OBSERVED_STATE" >>"$SAMPLES_FILE"
  SAMPLE_COUNT=$((SAMPLE_COUNT + 1))
  FINAL_MONO_NS="$sample_mono_ns"
  FINAL_CPU_SECONDS="$OBSERVED_CPU_SECONDS"
  PREVIOUS_MONO_NS="$sample_mono_ns"
  PREVIOUS_ELAPSED_SECONDS="$OBSERVED_ELAPSED_SECONDS"
  return 0
}

write_host_facts() {
  {
    printf 'captured_at_wall_utc='; /bin/date -u '+%Y-%m-%dT%H:%M:%SZ' || printf 'unavailable\n'
    printf 'hostname='; /bin/hostname || printf 'unavailable\n'
    printf 'uname='; /usr/bin/uname -a || printf 'unavailable\n'
    printf 'architecture='; /usr/bin/uname -m || printf 'unavailable\n'
    printf 'sw_vers:\n'; /usr/bin/sw_vers || printf 'unavailable\n'
    printf 'hardware_model_and_memory:\n'; /usr/sbin/sysctl -n hw.model hw.memsize || printf 'unavailable\n'
    printf 'logical_cpu_count:\n'; /usr/sbin/sysctl -n hw.ncpu || printf 'unavailable\n'
    printf 'power:\n'; /usr/bin/pmset -g batt || printf 'unavailable\n'
    printf 'power_settings:\n'; /usr/bin/pmset -g custom || printf 'unavailable\n'
    printf 'thermal_status:\n'; /usr/bin/pmset -g therm || printf 'unavailable\n'
    printf 'reference_host_requirement=physical Apple-silicon Mac, 16 GiB RAM, macOS 14 latest patch, internal display, AC power, Low Power Mode off, no VM/debugger\n'
  } >"$HOST_FILE"
}

write_artifact_facts() {
  {
    printf 'captured_at_wall_utc='; /bin/date -u '+%Y-%m-%dT%H:%M:%SZ' || printf 'unavailable\n'
    if [[ ! -f "$ARTIFACT_PATH" || -L "$ARTIFACT_PATH" ]]; then
      printf 'artifact_path=%s\n' "$ARTIFACT_PATH"
      printf 'artifact_sha256=missing or non-regular artifact\n'
      return 1
    fi
    local sha_line=''
    local sha=''
    if ! sha_line="$(/usr/bin/shasum -a 256 "$ARTIFACT_PATH")"; then
      return 1
    fi
    sha="${sha_line%% *}"
    if [[ ${#sha} -ne 64 ]]; then
      return 1
    fi
    if ! [[ "$sha" =~ ^[[:xdigit:]]{64}$ ]]; then
      return 1
    fi
    printf 'artifact_path=%s\n' "$ARTIFACT_PATH"
    printf 'artifact_sha256=%s\n' "$sha"
    printf 'artifact_stat='; /usr/bin/stat -f '%z bytes, mode %Sp, modified %Sm' "$ARTIFACT_PATH" || printf 'unavailable\n'
    printf 'notarization=not assessed by this sampler; verify ticket and staple separately\n'
    printf 'provider_terminal_state=not inferred by this sampler; attach operator evidence\n'
  } >"$ARTIFACT_FILE"
  ARTIFACT_FACTS_COMPLETE=true
}

write_host_facts || abort 'unable to retain host facts'
if ! write_artifact_facts; then
  abort 'artifact path was supplied but SHA-256 facts could not be recorded'
fi

if ! MEASUREMENT_START_WALL_UTC="$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"; then
  abort 'unable to record measurement start time'
fi
printf 'sample,pid,monotonic_ns,cpu_seconds,rss_kib,elapsed_seconds,state\n' >"$SAMPLES_FILE"

if sample_process 0; then
  :
else
  sample_status=$?
  case "$sample_status" in
    2) abort 'the explicit PID was replaced, exited, became a zombie, or elapsed time regressed' ;;
    *) abort 'baseline /bin/ps sample was missing or malformed' ;;
  esac
fi

sample_index=0
while (( sample_index < EXPECTED_INTERVALS )); do
  if ! /bin/sleep "$INTERVAL_SECONDS"; then
    abort '5-second sampler sleep was interrupted'
  fi
  sample_index=$((sample_index + 1))
  if sample_process "$sample_index"; then
    :
  else
    sample_status=$?
    case "$sample_status" in
      2) abort "stable-process check failed at sample $sample_index" ;;
      *) abort "missing or malformed /bin/ps sample at sample $sample_index" ;;
    esac
  fi
done

if (( SAMPLE_COUNT != EXPECTED_ROWS || INTERVAL_COUNT != EXPECTED_INTERVALS )); then
  GATE_ROWS=FAIL
  abort "expected 361 rows (baseline plus 360 intervals), observed $SAMPLE_COUNT rows and $INTERVAL_COUNT intervals"
fi
GATE_ROWS=PASS

if ! statistics="$(/usr/bin/awk -F, '
  NR == 1 {
    if ($1 != "sample" || $3 != "monotonic_ns" || $4 != "cpu_seconds" || $5 != "rss_kib") exit 2
    next
  }
  NF != 7 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 !~ /^[0-9]+([.][0-9]+)?$/ || $5 !~ /^[0-9]+$/ || $6 !~ /^[0-9]+([.][0-9]+)?$/ || $7 !~ /^[[:alnum:]_.+-]+$/ { exit 3 }
  {
    rows++
    rss_sum += $5
    if (rows == 1 || $5 > rss_max) rss_max = $5
  }
  END {
    if (rows != 361) exit 4
    printf "%d\t%.6f\t%d\n", rows, rss_sum / rows, rss_max
  }
' "$SAMPLES_FILE")"; then
  abort 'raw CSV aggregation failed or discarded a row'
fi
IFS=$'\t' read -r measured_rows RSS_MEAN_KIB RSS_MAX_KIB <<<"$statistics"
[[ "$measured_rows" == "$EXPECTED_ROWS" ]] || abort 'raw CSV row count changed during aggregation'

if [[ -z "$INITIAL_MONO_NS" || -z "$FINAL_MONO_NS" || -z "$INITIAL_CPU_SECONDS" || -z "$FINAL_CPU_SECONDS" ]]; then
  abort 'first/final cumulative CPU or monotonic samples are missing'
fi
if (( FINAL_MONO_NS <= INITIAL_MONO_NS )); then
  abort 'final monotonic timestamp did not advance'
fi
if ! /usr/bin/awk -v first="$INITIAL_CPU_SECONDS" -v final="$FINAL_CPU_SECONDS" \
  'BEGIN { exit !(final >= first) }'; then
  abort 'cumulative CPU time regressed'
fi

measurement_duration_ns=$((FINAL_MONO_NS - INITIAL_MONO_NS))
if ! CPU_PERCENT="$(/usr/bin/awk -v first="$INITIAL_CPU_SECONDS" -v final="$FINAL_CPU_SECONDS" -v duration_ns="$measurement_duration_ns" \
  'BEGIN {
    if (duration_ns <= 0) exit 2
    printf "%.6f\n", 100 * (final - first) / (duration_ns / 1000000000)
  }')"; then
  abort 'one-core CPU percentage calculation failed'
fi

if /usr/bin/awk -v value="$CPU_PERCENT" 'BEGIN { exit !(value < 1.00) }'; then
  GATE_CPU=PASS
else
  GATE_CPU=FAIL
  abort "one-core CPU percent is $CPU_PERCENT (required < 1.00)"
fi
if /usr/bin/awk -v value="$RSS_MAX_KIB" 'BEGIN { exit !(value < 102400) }'; then
  GATE_RSS=PASS
else
  GATE_RSS=FAIL
  abort "maximum RSS is $RSS_MAX_KIB KiB (required < 102400 KiB)"
fi

DRIFT_PERCENT="$(/usr/bin/awk -v count="$DRIFT_COUNT" -v intervals="$INTERVAL_COUNT" 'BEGIN { printf "%.6f", 100 * count / intervals }')"
if (( DRIFT_COUNT * 100 <= INTERVAL_COUNT )); then
  GATE_DRIFT=PASS
else
  GATE_DRIFT=FAIL
  abort "interval drift exceeded +/-1 second for $DRIFT_COUNT of $INTERVAL_COUNT intervals ($DRIFT_PERCENT%%)"
fi

STATUS=NUMERIC_PASS
FAILURE_REASON='none'
printf 'AC-11 numeric measurement: PASS; evidence retained in %s\n' "$EVIDENCE_DIR"
exit 0
