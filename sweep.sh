#!/bin/bash
# Runs the full knob sweep + stress. Exits 1 if any run REPRODUCED.
set -uo pipefail

BIN=./Probe.app/Contents/MacOS/Probe
ANY_REPRO=0

run() {
  local label="$1"; shift
  out=$(env "$@" "$BIN" 2>&1)
  verdict=$(echo "$out" | grep -E '^(NOT )?REPRODUCED' || true)
  will=$(echo "$out" | grep -c "] WILL" || true)
  did=$(echo "$out" | grep -c "] DID" || true)
  printf "%-52s %-18s (WILL=%s DID=%s)\n" "$label" "$verdict" "$will" "$did"
  if [[ "$verdict" == REPRODUCED* ]]; then
    ANY_REPRO=1
    echo "::group::log: $label"
    echo "$out"
    echo "::endgroup::"
  fi
}

echo "=== host ==="
sw_vers
echo "arch: $(uname -m)"
file "$BIN"
echo

echo "=== sanity: standalone child ==="
PROBE_CHILD=1 PROBE_INIT_SLEEP_MS=300 timeout 10 "$BIN" 2>&1 || echo "(exit $?)"
echo

echo "=== knob sweep (init_sleep=300ms, SIGKILL@150ms) ==="
run "N=12"                          PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1
run "N=40"                          PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_N=40
run "N=40 + Regular"                PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_N=40 PROBE_REGULAR=1
run "N=40 + Regular + zombies"      PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_N=40 PROBE_REGULAR=1 PROBE_SKIP_WAIT=1
run "N=40 + Regular + 5 alive"      PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_N=40 PROBE_REGULAR=1 PROBE_LEAVE_ALIVE=5
run "N=40 + Regular + 10 alive"     PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_N=40 PROBE_REGULAR=1 PROBE_LEAVE_ALIVE=10
run "init=800 kill@400 N=40 Reg"    PROBE_INIT_SLEEP_MS=800 PROBE_DELAY_MS=400 PROBE_SIGKILL=1 PROBE_N=40 PROBE_REGULAR=1
run "N=40 + Regular (SIGINT)"       PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150               PROBE_N=40 PROBE_REGULAR=1
run "N=40 delay=600"                PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=600 PROBE_SIGKILL=1 PROBE_N=40

echo
echo "=== stress 30x: N=40 + Regular + 3 alive + zombies ==="
repro=0
for i in $(seq 1 30); do
  v=$(PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_N=40 PROBE_REGULAR=1 PROBE_LEAVE_ALIVE=3 PROBE_SKIP_WAIT=1 "$BIN" 2>&1 | grep -E '^(NOT )?REPRODUCED' || true)
  printf "  iter %2d: %s\n" "$i" "$v"
  [[ "$v" == REPRODUCED* ]] && { repro=$((repro+1)); ANY_REPRO=1; }
done
echo "stress: $repro/30 reproduced"

echo
if [[ $ANY_REPRO -eq 1 ]]; then
  echo "::error::REPRODUCED on this host"
  exit 1
else
  echo "NOT REPRODUCED on this host"
  exit 0
fi
