# MQ Pre-flight Route Validator - Session Memory

**Last Updated:** 2025-12-11 12:27 UTC

---

## Project Overview

A dynamic MQ route validation tool that automatically discovers and validates the complete message path by following queue definitions - like an MQ Architect would.

**Key Design Principles:**
- **Dynamic Discovery** - Only needs starting QMgr + Queue name, discovers entire route automatically
- **No Hardcoding** - Works with ANY MQ environment with just connection config
- **External Boundary = NOT an Error** - QMgrs not in config are treated as route boundary (external destination), not failures
- **Multi-hop Routing** - Correctly handles intermediate gateways (e.g., MEM1 → GW → OMNI)

---

## Files

| File | Purpose |
|------|---------|
| `mq_preflight_validator.sh` | Main validation script |
| `mq_config.yaml` | QMgr connection details |

---

## Usage

```bash
# Basic validation
./mq_preflight_validator.sh --qmgr APEX.C1.MEM1 --queue APEX.TO.OMNI.WIRE.REQ

# Verbose mode (detailed output)
./mq_preflight_validator.sh --qmgr APEX.C1.MEM1 --queue APEX.TO.OMNI.WIRE.REQ -v
```

---

## Current QMgr Config (mq_config.yaml)

| QMgr | Host | Port | Channel |
|------|------|------|---------|
| APEX.C1.MEM1 | apex.c1.mem1.microaxle.lab | 6002 | ADMIN.SVRCONN |
| APEX.C2.MEM1 | apex.c2.mem1.microaxle.lab | 7002 | ADMIN.SVRCONN |
| APEX.GW.QM | apex.gw.qm.microaxle.lab | 5001 | ADMIN.SVRCONN |
| OMNI.QM | *External - no access* | - | - |
| APEX.C2.MEM2 | *NOT IN CONFIG - needs to be added* | - | - |

All connections use SSL: `ANY_TLS12_OR_HIGHER`

---

## Route Discovery Logic

```
1. Start at QMGR1, check queue type
2. If QREMOTE:
   - Get RQMNAME (final destination) and XMITQ
   - If XMITQ different from RQMNAME → Multi-hop routing
   - Follow XMITQ chain to intermediate QMgr
3. On intermediate QMgr:
   - Check for XMITQ to final destination
   - Validate sender channel
4. Continue until:
   - QLOCAL found (final destination)
   - QMgr not in config (external boundary)
```

---

## MQ Object Types Shown in Flow

| Type | What It Is | Info Collected |
|------|------------|----------------|
| **QMGR** | Queue Manager | Status (Online/Offline), Role (Origin/Gateway/Destination) |
| **QLOCAL** | Local Queue | Depth, MaxDepth, IPPROCS, OPPROCS |
| **QREMOTE** | Remote Queue Def | Target QMgr (→ RQMNAME) |
| **QALIAS** | Alias Queue | Target, Target Type |
| **XMITQ** | Transmission Queue | Depth/MaxDepth |
| **SDR** | Sender Channel | PING test result, CONNAME |
| **RCVR** | Receiver Channel | Status on receiving QMgr |

---

## Status Codes in Output

| Status | Meaning |
|--------|---------|
| `[OK] RUNNING` | Channel actively running |
| `[OK] READY` | Channel defined and PING successful |
| `[OK] Online` | QMgr connected |
| `[--] IDLE` | Inactive but defined (triggered channel) |
| `[--] WAITING` | RCVR waiting for connection |
| `[!!] NOREACH` | PING failed (connectivity issue) |
| `[!!] NO DEF` | Channel not defined |
| `[!!] RETRY` | Channel retrying connection |
| `[!!] STOPPED` | Channel manually stopped |
| `[EXT]` | External QMgr (boundary - NOT an error) |

---

## Output Format

Executive Summary with:
1. **Header** - Report title + timestamp (centered in box)
2. **Route Visualization** - `● QMGR1 ───► ● QMGR2 ───► ◐ EXTERNAL [EXT]`
3. **Objects Table** - All objects in flow order with:
   - Step #, Type, Name, Status, Info/Stats
   - SDR channels with PING test results
   - RCVR channels on receiving QMgr
4. **Issues Section** - Any problems detected
5. **Health Bar** - Pass/Fail/Warning counts + percentage bar
6. **Verdict Box** - HEALTHY / INCOMPLETE / ISSUES

---

## Test Cases Validated

| Starting QMgr | Queue | Route Discovered | Status |
|---------------|-------|------------------|--------|
| APEX.C1.MEM1 | APEX.TO.OMNI.WIRE.REQ | MEM1 → GW → OMNI.QM [EXT] | ✓ HEALTHY (external boundary) |
| APEX.C1.MEM1 | APEX.GW.QM | MEM1 (QLOCAL - destination) | ✓ HEALTHY |
| APEX.C1.MEM1 | FIN.TO.OPS.AUDIT.REQ | MEM1 → GW → C2.MEM2 [EXT] | ✓ HEALTHY (external boundary) |

---

## Multi-Hop Routing Example

```
APEX.C1.MEM1                      APEX.GW.QM                       OMNI.QM
┌──────────────┐                 ┌──────────────┐                ┌──────────────┐
│ QREMOTE      │                 │ QREMOTE      │                │ QLOCAL       │
│ RQMNAME:     │──► XMITQ: ──────│ RQMNAME:     │──► XMITQ: ─────│ (destination)│
│   OMNI.QM    │    APEX.GW.QM   │   OMNI.QM    │    OMNI.QM.*   │              │
│ XMITQ:       │    Channel:     │              │    Channel:    │              │
│   APEX.GW.QM │    C1M1.TO.GW   │              │    APEX.TO.OMNI│              │
└──────────────┘                 └──────────────┘                └──────────────┘
```

**Key Point:** XMITQ on MEM1 points to GW (intermediate), not OMNI (final). Message header contains final destination, GW routes accordingly.

---

## Connection Method

Uses **runmqsc client connection** via JSON CCDT (Channel Connection Definition Table):
- No SSH required
- Connects remotely to each QMgr
- SSL/TLS supported
- CCDT generated dynamically per connection

---

## Recent Improvements (2025-12-11)

1. ✓ Added PING CHANNEL test for SDR channels (AMQ8020I = success)
2. ✓ Added RCVR channel status on receiving QMgr
3. ✓ Fixed table alignment issues
4. ✓ Clear status codes that fit in 13 char column
5. ✓ Shows both SDR and RCVR for each channel pair
6. ✓ **External QMgr = boundary, NOT an error** - `[EXT]` shown with "ROUTE HEALTHY"
7. ✓ Proper object flow order: QMGR → objects → (next hop) QMGR → RCVR → objects...

---

## Key Design Confirmations

- **No Hardcoding** - All logic is generic, no QMgr/Queue/Channel names hardcoded
- **Dynamic Discovery** - Follows QREMOTE → XMITQ → SDR → RCVR → next QMGR chain automatically
- **Object Display Order** - Sequential flow: QMGR status first, then its objects
- **External Boundary** - QMgr not in config = `[EXT]` boundary (NOT error), route shows HEALTHY

---

## Next Session Tasks

1. Add more object stats (listener status, etc.)
2. Test with more complex topologies
3. Add `--all-queues` option to validate all queues on a QMgr
4. Handle cluster queues with workload balancing
