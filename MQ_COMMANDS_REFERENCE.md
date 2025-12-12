# IBM MQ Commands Used in Connection Test Script

This document lists all IBM MQ commands and utilities used in the `mq_connection_test.sh` script, along with their purpose and benefits.

---

## 1. MQ Command Line Utilities

### 1.1 `dspmq` - Display Queue Manager
**Usage in script:**
```bash
dspmq -m "$qmgr"
```

**Purpose:**
- Displays information about queue managers
- Checks if a queue manager exists
- Retrieves queue manager status (Running, Stopped, etc.)

**Benefits:**
- **Quick Status Check**: Fast way to verify if a queue manager is available and running
- **Existence Verification**: Confirms queue manager exists before attempting operations
- **Status Parsing**: Provides structured output that can be parsed programmatically
- **No MQSC Required**: Standalone utility, doesn't require MQSC session

**Example Output:**
```
QMNAME(APEX.C1.MEM1) STATUS(Running)
```

---

### 1.2 `runmqsc` - Run MQSC Commands
**Usage in script:**
```bash
echo "DISPLAY QLOCAL('$queue')" | runmqsc "$qmgr"
```

**Purpose:**
- Executes MQSC (MQ Script Commands) interactively or from stdin
- Primary interface for querying and managing MQ objects
- Used for all object discovery operations

**Benefits:**
- **Programmatic Access**: Allows scripts to interact with MQ programmatically
- **Batch Operations**: Can execute multiple commands in sequence
- **Standard Interface**: Uses standard MQSC command syntax
- **Error Handling**: Returns structured error codes and messages
- **Flexible Input**: Accepts commands from stdin, files, or command line

---

### 1.3 `amqsput` - Put Message Utility
**Usage in script:**
```bash
printf "%s\n\n" "$test_msg" | amqsput "$target_queue" "$qmgr"
```

**Purpose:**
- Sample utility provided with IBM MQ for putting messages to queues
- Reads message content from stdin
- Sends messages to specified queue on specified queue manager

**Benefits:**
- **Simple Interface**: Easy-to-use command-line tool for message sending
- **Reliable**: Official IBM MQ utility, well-tested
- **Standard Method**: Industry-standard way to send test messages
- **No Scripting Required**: Simpler than using MQSC PUT command
- **Error Handling**: Provides clear success/failure feedback

**Note:** Script dynamically discovers `amqsput` in common locations:
- `/opt/mqm/samp/bin/amqsput`
- `/usr/mqm/samp/bin/amqsput`
- System PATH

---

## 2. MQSC Commands (via `runmqsc`)

### 2.1 `DISPLAY QREMOTE` - Display Remote Queue
**Usage in script:**
```bash
DISPLAY QREMOTE('$queue')
DISPLAY QREMOTE('$queue') XMITQ
DISPLAY QREMOTE('$queue') RQMNAME
```

**Purpose:**
- Displays definition and attributes of a remote queue
- Retrieves transmission queue (XMITQ) associated with remote queue
- Gets target queue manager name (RQMNAME)

**Benefits:**
- **Queue Type Detection**: Identifies if a queue is remote vs local
- **Transmission Queue Discovery**: Automatically finds the XMITQ for remote queues
- **Target Discovery**: Identifies target queue manager for remote queues
- **Complete Information**: Provides all remote queue attributes

**Key Attributes Retrieved:**
- `TYPE(QREMOTE)` - Confirms it's a remote queue
- `XMITQ(...)` - Transmission queue name
- `RQMNAME(...)` - Target queue manager name

---

### 2.2 `DISPLAY QLOCAL` - Display Local Queue
**Usage in script:**
```bash
DISPLAY QLOCAL('$queue')
DISPLAY QLOCAL('$queue') XMITQ
DISPLAY QLOCAL('$xmitq') CURDEPTH
```

**Purpose:**
- Displays definition and attributes of a local queue
- Retrieves transmission queue attribute (if set)
- Gets current queue depth (CURDEPTH) - number of messages in queue

**Benefits:**
- **Queue Verification**: Confirms queue exists and is accessible
- **Depth Monitoring**: Tracks message count for verification
- **Attribute Discovery**: Retrieves all queue configuration
- **Transmission Queue**: Some local queues may have XMITQ set

**Key Attributes Retrieved:**
- `CURDEPTH(...)` - Current number of messages in queue
- `XMITQ(...)` - Transmission queue (if configured)
- `TYPE(QLOCAL)` - Confirms it's a local queue

---

### 2.3 `DISPLAY CHANNEL` - Display Channel Definition
**Usage in script:**
```bash
DISPLAY CHANNEL(*)
DISPLAY CHANNEL(*) XMITQ
DISPLAY CHANNEL(*) CHLTYPE(SDR)
DISPLAY CHANNEL(*) CHLTYPE(RCVR)
DISPLAY CHANNEL('$channel') CONNAME
DISPLAY CHANNEL('$channel') TARGQMGR
```

**Purpose:**
- Lists all channels or displays specific channel definition
- Finds channels by type (SDR, RCVR)
- Retrieves channel attributes (XMITQ, CONNAME, TARGQMGR)

**Benefits:**
- **Channel Discovery**: Finds channels associated with transmission queues
- **Type Filtering**: Filters by channel type (sender/receiver)
- **Attribute Retrieval**: Gets connection names and target queue managers
- **Wildcard Support**: `*` allows listing all channels

**Key Attributes Retrieved:**
- `XMITQ(...)` - Transmission queue used by channel
- `CHLTYPE(SDR/RCVR)` - Channel type
- `CONNAME(...)` - Connection name (host:port)
- `TARGQMGR(...)` - Target queue manager name

---

### 2.4 `DISPLAY CHSTATUS` - Display Channel Status
**Usage in script:**
```bash
DISPLAY CHSTATUS('$channel')
```

**Purpose:**
- Shows runtime status of a channel
- Indicates if channel is active/running
- Provides channel state and substate information

**Benefits:**
- **Runtime Status**: Real-time channel activity status
- **State Information**: Shows if channel is RUNNING, INACTIVE, etc.
- **Health Check**: Determines if channel is operational
- **Troubleshooting**: Helps identify channel issues

**Key Attributes Retrieved:**
- `STATUS(...)` - Channel status
- `STATE(...)` - Channel state (RUNNING, INACTIVE, etc.)
- `SUBSTATE(...)` - Additional state information

**Note:** Returns "Channel Status not found" if channel is not active.

---

### 2.5 `PING CHL` - Ping Channel
**Usage in script:**
```bash
PING CHL('$channel')
```

**Purpose:**
- Tests channel connectivity and configuration
- Verifies channel definition exists and is reachable
- Checks if channel can be activated/connected

**Benefits:**
- **Connectivity Test**: Verifies channel can be reached
- **Configuration Validation**: Confirms channel is properly configured
- **Non-Intrusive**: Read-only operation, doesn't start channel
- **Quick Check**: Fast way to test channel without activating it
- **Error Detection**: Identifies configuration issues

**Success Indicators:**
- `AMQ9501I: Channel 'xxx' ping successful.`
- `AMQ9514E: Channel 'xxx' is in use.` (actually indicates channel is active - good!)

**Failure Indicators:**
- `AMQ8144E: Channel 'xxx' not found.`
- Other AMQ error codes

---

### 2.6 `PUT` - Put Message (MQSC)
**Usage in script:**
```bash
PUT '$target_queue'
$test_msg
```

**Purpose:**
- Places a message into a queue using MQSC
- Alternative to `amqsput` utility
- Used as fallback when `amqsput` is not available

**Benefits:**
- **Fallback Method**: Works when `amqsput` is not installed
- **Direct MQSC**: Uses native MQSC command
- **Script Integration**: Can be embedded in MQSC scripts
- **Reliable**: Standard MQ operation

**Note:** Script uses this as fallback when `amqsput` is not found.

---

## 3. Command Usage Summary

### Discovery Flow:
1. **`dspmq`** → Check queue manager status
2. **`DISPLAY QREMOTE/QLOCAL`** → Discover queue type and transmission queue
3. **`DISPLAY QLOCAL CURDEPTH`** → Get queue depth
4. **`DISPLAY CHANNEL(*) XMITQ`** → Find sender channel
5. **`DISPLAY CHSTATUS`** → Check channel status
6. **`PING CHL`** → Test channel connectivity (if inactive)
7. **`DISPLAY QREMOTE RQMNAME`** → Get target queue manager
8. **`DISPLAY CHANNEL TARGQMGR`** → Alternative way to get target QMgr
9. **`DISPLAY CHANNEL(*) CHLTYPE(RCVR)`** → Find receiver channel

### Message Sending:
1. **`amqsput`** (preferred) → Send message via utility
2. **`PUT`** (fallback) → Send message via MQSC

---

## 4. Benefits of This Command Strategy

### 4.1 Dynamic Discovery
- **No Hardcoding**: Script discovers all objects automatically
- **Flexible**: Works with any MQ configuration
- **Portable**: Adapts to different MQ environments

### 4.2 Comprehensive Coverage
- **Complete Picture**: Discovers all related MQ objects
- **End-to-End**: Traces path from source to target
- **Status Monitoring**: Checks runtime status of all components

### 4.3 Error Prevention
- **Validation**: Verifies objects exist before using them
- **Status Checks**: Ensures queue managers are running
- **Connectivity Tests**: Pings channels to verify configuration

### 4.4 Troubleshooting Support
- **Detailed Information**: Provides depth, status, state information
- **Ping Results**: Shows if inactive channels can be activated
- **Clear Errors**: Uses standard MQ error codes

### 4.5 Non-Intrusive Operations
- **Read-Only Discovery**: All discovery commands are read-only
- **No Modifications**: Doesn't change MQ configuration
- **Safe Testing**: Ping doesn't start channels, just tests them

---

## 5. Command Execution Pattern

All MQSC commands follow this pattern:
```bash
echo "MQSC_COMMAND" | runmqsc "$qmgr" 2>/dev/null
```

**Why this pattern?**
- **Piping**: Sends command to `runmqsc` via stdin
- **Error Suppression**: `2>/dev/null` suppresses stderr (errors handled separately)
- **Output Capture**: Output can be parsed with `grep`, `sed`, `awk`
- **Non-Interactive**: Works in scripts without user interaction

---

## 6. Error Handling

The script handles MQ errors by:
1. **Checking Exit Codes**: `runmqsc` returns non-zero on errors
2. **Parsing Error Messages**: Looks for AMQ error codes (AMQxxxxE)
3. **Graceful Degradation**: Continues with available information
4. **Clear Reporting**: Shows "Not found" or "FAILED" in summary

---

## 7. Performance Considerations

- **Efficient Queries**: Uses specific object names when possible
- **Wildcard Usage**: Only when necessary (channel discovery)
- **Caching**: Stores results in variables to avoid repeated queries
- **Parallel Operations**: Could be optimized for parallel channel checks

---

## Summary

The script uses **8 distinct MQ commands/utilities**:
1. `dspmq` - Queue manager status
2. `runmqsc` - MQSC command executor
3. `amqsput` - Message sending utility
4. `DISPLAY QREMOTE` - Remote queue discovery
5. `DISPLAY QLOCAL` - Local queue discovery
6. `DISPLAY CHANNEL` - Channel discovery
7. `DISPLAY CHSTATUS` - Channel status
8. `PING CHL` - Channel connectivity test
9. `PUT` - Message sending (fallback)

All commands work together to provide:
- ✅ Complete auto-discovery
- ✅ Status verification
- ✅ Connectivity testing
- ✅ Message delivery verification
- ✅ Comprehensive troubleshooting information

