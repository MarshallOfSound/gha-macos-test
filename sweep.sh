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
  printf "%-55s %-18s (WILL=%s DID=%s)\n" "$label" "$verdict" "$will" "$did"
  if [[ "$verdict" == REPRODUCED* ]]; then
    ANY_REPRO=1
    echo "::group::log: $label"
    echo "$out"
    echo "::endgroup::"
  fi
}

echo "=== host ==="
sw_vers; echo "arch: $(uname -m)"; file "$BIN"; echo

echo "=== sanity: standalone child ==="
PROBE_CHILD=exit PROBE_INIT_SLEEP_MS=300 timeout 10 "$BIN" 2>&1 || echo "(exit $?)"
echo

echo "=== A. live-orphan sweep (the PR-51476 scenario) ==="
for n in 1 2 3 5 10 20; do
  run "orphans=$n"             PROBE_LEAVE_ALIVE=$n PROBE_N=0 PROBE_INIT_SLEEP_MS=300 PROBE_REGULAR=1
done
for n in 3 10; do
  run "orphans=$n + window"    PROBE_LEAVE_ALIVE=$n PROBE_N=0 PROBE_INIT_SLEEP_MS=300 PROBE_REGULAR=1 PROBE_WINDOW=1
done
for n in 3 10; do
  run "orphans=$n + churn=20"  PROBE_LEAVE_ALIVE=$n PROBE_N=20 PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_REGULAR=1
done

echo
echo "=== A2. stuck-orphan sweep (orphan got WILL, never pumps oapp) ==="
for n in 1 2 3 5 10; do
  run "stuck orphans=$n"       PROBE_LEAVE_ALIVE=$n PROBE_ORPHAN_STUCK=1 PROBE_N=0 PROBE_INIT_SLEEP_MS=300 PROBE_REGULAR=1
done

echo
echo "=== B. churn-only sweep ==="
run "churn N=12"                       PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1
run "churn N=40 + Regular"             PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_N=40 PROBE_REGULAR=1
run "churn N=40 + Regular + zombies"   PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_N=40 PROBE_REGULAR=1 PROBE_SKIP_WAIT=1

echo
echo "=== C. stress 30x: 10 windowed orphans + churn=20 ==="
repro=0
for i in $(seq 1 30); do
  v=$(PROBE_LEAVE_ALIVE=10 PROBE_N=20 PROBE_INIT_SLEEP_MS=300 PROBE_DELAY_MS=150 PROBE_SIGKILL=1 PROBE_REGULAR=1 PROBE_WINDOW=1 "$BIN" 2>&1 | grep -E '^(NOT )?REPRODUCED' || true)
  printf "  iter %2d: %s\n" "$i" "$v"
  [[ "$v" == REPRODUCED* ]] && { repro=$((repro+1)); ANY_REPRO=1; }
done
echo "stress: $repro/30 reproduced"

echo
if [[ $ANY_REPRO -eq 1 ]]; then
  echo "::error::REPRODUCED on this host"
  exit 1
fi
echo "NOT REPRODUCED on this host"
