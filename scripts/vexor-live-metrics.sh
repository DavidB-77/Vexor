#!/bin/bash
set -euo pipefail

# Live validator metrics via RPC (TPS + finality lag)
RPC_URL="${RPC_URL:-http://127.0.0.1:8899}"
SAMPLES="${SAMPLES:-5}"

python3 - <<'PY'
import json, time, urllib.request, os, sys

rpc_url = os.environ.get("RPC_URL", "http://127.0.0.1:8899")
samples = int(os.environ.get("SAMPLES", "5"))

def rpc(method, params=None):
    payload = {"jsonrpc": "2.0", "id": 1, "method": method}
    if params is not None:
        payload["params"] = params
    req = urllib.request.Request(
        rpc_url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=5) as r:
        return json.load(r)["result"]

def get_slot(commitment):
    return rpc("getSlot", [{"commitment": commitment}])

def get_block_time(slot):
    try:
        return rpc("getBlockTime", [slot])
    except Exception:
        return None

perf = rpc("getRecentPerformanceSamples", [samples])
if not perf:
    print("No performance samples available")
    sys.exit(1)

total_tx = sum(p.get("numTransactions", 0) for p in perf)
total_secs = sum(p.get("samplePeriodSecs", 0) for p in perf)
tps = (total_tx / total_secs) if total_secs else 0.0

slot_processed = get_slot("processed")
slot_confirmed = get_slot("confirmed")
slot_finalized = get_slot("finalized")

finalized_time = get_block_time(slot_finalized)
now = int(time.time())
finality_age = (now - finalized_time) if finalized_time else None

print(f"rpc_url={rpc_url}")
print(f"tps_avg_{samples}samples={tps:.2f}")
print(f"slot_processed={slot_processed}")
print(f"slot_confirmed={slot_confirmed}")
print(f"slot_finalized={slot_finalized}")
print(f"slot_lag_processed_finalized={slot_processed - slot_finalized}")
if finality_age is not None:
    print(f"finality_age_seconds={finality_age}")
else:
    print("finality_age_seconds=unknown")
PY
