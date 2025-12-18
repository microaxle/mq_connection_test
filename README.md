# IBM MQ Edge Connection Check

A shell script to test and verify IBM MQ connectivity between DTCC BE Queue Manager and Client Queue Manager.

## What It Does

1. Validates DTCC BE QMgr is running
2. Checks Client Alias (QREMOTE) configuration
3. Verifies XMITQ and RQMNAME attributes
4. Finds associated Sender Channel and checks its status
5. Performs PING test for non-running channels
6. Optionally sends a test message and verifies delivery

## Usage

```bash
./edge_connection_check.sh <DTCC_BE_QMgr> <Client_Queue> <Client_Alias> [-s [MSG]] [-v]
```

### Parameters

| Parameter | Description |
|-----------|-------------|
| `DTCC_BE_QMgr` | Source DTCC Backend Queue Manager |
| `Client_Queue` | Target queue on client side |
| `Client_Alias` | Remote queue definition (QREMOTE) pointing to client |
| `-s [MSG]` | Send test message (optional custom text) |
| `-v` | Verbose mode for debugging |

### Examples

```bash
# Check connectivity only
./edge_connection_check.sh DTCC.QM1 CLIENT.QUEUE CLIENT.ALIAS

# Check with verbose output
./edge_connection_check.sh DTCC.QM1 CLIENT.QUEUE CLIENT.ALIAS -v

# Send test message
./edge_connection_check.sh DTCC.QM1 CLIENT.QUEUE CLIENT.ALIAS -s

# Send test message with custom content
./edge_connection_check.sh DTCC.QM1 CLIENT.QUEUE CLIENT.ALIAS -s "My test message"

# Send message with verbose debugging
./edge_connection_check.sh DTCC.QM1 CLIENT.QUEUE CLIENT.ALIAS -s -v

# Save debug output to file
./edge_connection_check.sh DTCC.QM1 CLIENT.QUEUE CLIENT.ALIAS -v 2>debug.log
```

## Output Summary

```
====================================================================================
                           EDGE CONNECTION SUMMARY
====================================================================================
  DTCC BE QMgr         : DTCC.QM1
  Client Queue         : CLIENT.QUEUE
  Client Alias         : CLIENT.ALIAS
  Client QMgr          : CLIENT.QM1
------------------------------------------------------------------------------------
  [BEFORE] Connectivity Status
------------------------------------------------------------------------------------
  XMITQ                : CLIENT.QM1.XMIT
  XMITQ Depth          : 0
  Sender Channel       : TO.CLIENT.QM1
  Channel Status       : RUNNING
------------------------------------------------------------------------------------
  [AFTER] Message Delivery Proof
------------------------------------------------------------------------------------
  Result               : SUCCESS
  Status               : Transmitted (message left XMITQ)
  Message Size         : 95 bytes
  XMITQ Depth          : 0
  Message              : MQ_TEST_MSG|2024-12-18 15:30:00|Client Queue: CLIENT.QUEUE|...
====================================================================================
```

## Channel Status Handling

| Status | Ping Action | Description |
|--------|-------------|-------------|
| RUNNING | Skipped | Channel is healthy |
| BINDING/STARTING/INITIALIZING | Skipped | Channel is starting |
| STOPPING | Skipped | Channel is stopping |
| INACTIVE | Performed | No channel instance |
| STOPPED/RETRYING/PAUSED | Performed | Needs diagnostic |

## Message Delivery Result

| Condition | Result | Meaning |
|-----------|--------|---------|
| Message left XMITQ | SUCCESS | Delivered to remote QMgr |
| Message stuck in XMITQ | FAILED | Channel not transmitting |
| amqsput failed | FAILED | Could not put message |

## Test Message Format

```
MQ_TEST_MSG|[Custom Message|]YYYY-MM-DD HH:MM:SS|Client Queue: <name>|Client QMgr: <name>|DTCC QMgr: <name>
```

## Exit Codes

| Code | Description |
|------|-------------|
| 0 | Success |
| 1 | Error or message delivery failed |

## Requirements

- IBM MQ installed (`runmqsc`, `dspmq` commands)
- `amqsput` utility (for `-s` flag)
- Appropriate permissions to access queue managers

## Error Handling

The script validates:
- DTCC BE QMgr is running
- Client Alias (QREMOTE) exists
- XMITQ attribute is configured
- RQMNAME attribute is configured
