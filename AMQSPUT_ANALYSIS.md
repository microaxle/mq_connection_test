# In-Depth Analysis of IBM MQ Sample Program: amqsput

## Table of Contents
1. [Overview](#overview)
2. [Program Purpose and Functionality](#program-purpose-and-functionality)
3. [Command-Line Parameters](#command-line-parameters)
4. [Internal Architecture](#internal-architecture)
5. [MQI (Message Queue Interface) Calls](#mqi-message-queue-interface-calls)
6. [Data Structures](#data-structures)
7. [Program Flow](#program-flow)
8. [Message Processing Logic](#message-processing-logic)
9. [Error Handling](#error-handling)
10. [Authentication Support](#authentication-support)
11. [Usage Examples](#usage-examples)
12. [Key Implementation Details](#key-implementation-details)
13. [Limitations and Considerations](#limitations-and-considerations)

---

## Overview

**Program Name:** `amqsput` (compiled from `amqsput0.c`)

**Type:** IBM MQ Sample C Program

**Purpose:** A command-line utility that puts messages to an IBM MQ queue by reading text from standard input (stdin).

**Source Location:** `/opt/mqm/samp/amqsput0.c`

**Binary Location:** `/opt/mqm/samp/bin/amqsput`

**Copyright:** IBM Corp. 1994-2024

---

## Program Purpose and Functionality

`amqsput` is a sample program that demonstrates the use of the **MQPUT** MQI call. It serves as:

1. **Educational Tool**: Shows how to use IBM MQ Message Queue Interface (MQI) to send messages
2. **Testing Utility**: Allows quick testing of message delivery to queues
3. **Script Integration**: Can be used in shell scripts and automation workflows
4. **Reference Implementation**: Provides a template for developing custom MQ applications

### Core Functionality:
- Connects to a queue manager
- Opens a target queue for output
- Reads lines of text from stdin
- Sends each line as a separate datagram message
- Stops when it encounters an empty line or EOF
- Closes the queue and disconnects

---

## Command-Line Parameters

### Syntax:
```bash
amqsput [queue_name] [queue_manager] [open_options] [close_options] [target_qmgr] [dynamic_queue]
```

### Parameter Details:

#### 1. **queue_name** (Required - Position 1)
- **Type:** String
- **Description:** Name of the target queue where messages will be sent
- **Example:** `APEX.TO.OMNI.WIRE.REQ`
- **Validation:** Must be provided, otherwise program exits with code 99
- **Storage:** Stored in `od.ObjectName` (MQOD structure)

#### 2. **queue_manager** (Optional - Position 2)
- **Type:** String
- **Description:** Name of the queue manager to connect to
- **Default:** If not provided, connects to the default queue manager
- **Maximum Length:** `MQ_Q_MGR_NAME_LENGTH` (48 characters)
- **Storage:** Stored in `QMName` array
- **Usage:** Passed to `MQCONNX()` call

#### 3. **open_options** (Optional - Position 3)
- **Type:** Integer (decimal or hexadecimal)
- **Description:** Options for the `MQOPEN` call
- **Default:** `MQOO_OUTPUT | MQOO_FAIL_IF_QUIESCING` (0x2010 = 8208 decimal)
  - `MQOO_OUTPUT`: Open queue for output (put messages)
  - `MQOO_FAIL_IF_QUIESCING`: Fail if queue manager is stopping
- **Usage:** Converted using `atoi()` and stored in `O_options`
- **Example:** `8208` or `0x2010`

#### 4. **close_options** (Optional - Position 4)
- **Type:** Integer
- **Description:** Options for the `MQCLOSE` call
- **Default:** `MQCO_NONE` (0)
- **Usage:** Converted using `atoi()` and stored in `C_options`
- **Example:** `0`

#### 5. **target_qmgr** (Optional - Position 5)
- **Type:** String
- **Description:** Name of the target queue manager (for remote queues)
- **Maximum Length:** `MQ_Q_MGR_NAME_LENGTH` (48 characters)
- **Storage:** Stored in `od.ObjectQMgrName` (MQOD structure)
- **Use Case:** Used when putting messages to a queue on a different queue manager

#### 6. **dynamic_queue** (Optional - Position 6)
- **Type:** String
- **Description:** Name of a dynamic queue
- **Maximum Length:** `MQ_Q_NAME_LENGTH` (48 characters)
- **Storage:** Stored in `od.DynamicQName` (MQOD structure)
- **Use Case:** Used with model queues to create dynamic queues

### Parameter Validation:
```c
if (argc < 2)
{
    printf("Required parameter missing - queue name\n");
    exit(99);
}
```

---

## Internal Architecture

### Program Structure:
```
┌─────────────────────────────────────┐
│  Command-Line Argument Parsing      │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Authentication Setup (if enabled)   │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  MQCONNX - Connect to Queue Manager  │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  MQOPEN - Open Target Queue          │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Read from stdin (fgets loop)        │
│  ├─ Remove newline characters        │
│  ├─ Check for empty line/EOF          │
│  └─ MQPUT each line as message       │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  MQCLOSE - Close Queue               │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  MQDISC - Disconnect from QMgr       │
└──────────────────────────────────────┘
```

---

## MQI (Message Queue Interface) Calls

The program uses the following MQI calls in sequence:

### 1. **MQCONNX** - Connect to Queue Manager
```c
MQCONNX(QMName,      // Queue manager name (NULL for default)
        &cno,        // Connection options (includes auth if enabled)
        &Hcon,       // Connection handle (output)
        &CompCode,   // Completion code (output)
        &CReason);   // Reason code (output)
```

**Purpose:** Establishes a connection to the queue manager

**Parameters:**
- `QMName`: Queue manager name (empty string = default)
- `&cno`: Connection options structure (may include authentication)
- `&Hcon`: Returns connection handle for subsequent calls
- `&CompCode`: Returns `MQCC_OK`, `MQCC_WARNING`, or `MQCC_FAILED`
- `&CReason`: Returns reason code if not successful

**Error Handling:**
- If `CompCode == MQCC_FAILED`: Prints reason code and exits
- If `CompCode == MQCC_WARNING`: Prints warning but continues

### 2. **MQOPEN** - Open Queue for Output
```c
MQOPEN(Hcon,         // Connection handle
       &od,          // Object descriptor (queue name, etc.)
       O_options,    // Open options (MQOO_OUTPUT, etc.)
       &Hobj,        // Object handle (output)
       &OpenCode,    // Completion code (output)
       &Reason);     // Reason code (output)
```

**Purpose:** Opens the target queue for putting messages

**Parameters:**
- `Hcon`: Connection handle from `MQCONNX`
- `&od`: Object descriptor containing queue name
- `O_options`: Open options (default: `MQOO_OUTPUT | MQOO_FAIL_IF_QUIESCING`)
- `&Hobj`: Returns object handle for `MQPUT` and `MQCLOSE`
- `&OpenCode`: Returns completion code
- `&Reason`: Returns reason code if not successful

**Default Options:**
```c
O_options = MQOO_OUTPUT            // Open for output (put messages)
          | MQOO_FAIL_IF_QUIESCING // Fail if queue manager stopping
          ;                        // = 0x2010 = 8208 decimal
```

### 3. **MQPUT** - Put Message to Queue
```c
MQPUT(Hcon,          // Connection handle
      Hobj,          // Object handle (from MQOPEN)
      &md,           // Message descriptor
      &pmo,          // Put message options
      messlen,       // Message length
      buffer,        // Message buffer (data)
      &CompCode,     // Completion code (output)
      &Reason);      // Reason code (output)
```

**Purpose:** Sends a message to the opened queue

**Parameters:**
- `Hcon`: Connection handle
- `Hobj`: Object handle from `MQOPEN`
- `&md`: Message descriptor (format, message ID, etc.)
- `&pmo`: Put message options
- `messlen`: Length of message data
- `buffer`: Pointer to message data
- `&CompCode`: Returns completion code
- `&Reason`: Returns reason code if not successful

**Put Message Options:**
```c
pmo.Options = MQPMO_NO_SYNCPOINT      // No syncpoint (non-transactional)
            | MQPMO_FAIL_IF_QUIESCING; // Fail if queue manager stopping
```

### 4. **MQCLOSE** - Close Queue
```c
MQCLOSE(Hcon,        // Connection handle
        &Hobj,       // Object handle (from MQOPEN)
        C_options,   // Close options (default: MQCO_NONE)
        &CompCode,   // Completion code (output)
        &Reason);    // Reason code (output)
```

**Purpose:** Closes the queue handle

**Parameters:**
- `Hcon`: Connection handle
- `&Hobj`: Object handle to close
- `C_options`: Close options (default: `MQCO_NONE`)
- `&CompCode`: Returns completion code
- `&Reason`: Returns reason code if not successful

### 5. **MQDISC** - Disconnect from Queue Manager
```c
MQDISC(&Hcon,        // Connection handle (input/output)
       &CompCode,    // Completion code (output)
       &Reason);     // Reason code (output)
```

**Purpose:** Disconnects from the queue manager

**Parameters:**
- `&Hcon`: Connection handle (set to `MQHC_UNUSABLE_HCONN` on success)
- `&CompCode`: Returns completion code
- `&Reason`: Returns reason code if not successful

**Note:** Only called if not already connected (checks `CReason != MQRC_ALREADY_CONNECTED`)

---

## Data Structures

### 1. **MQOD** - Object Descriptor
```c
MQOD od = {MQOD_DEFAULT};
```

**Fields Used:**
- `ObjectName`: Target queue name (from argv[1])
- `ObjectQMgrName`: Target queue manager name (from argv[5], optional)
- `DynamicQName`: Dynamic queue name (from argv[6], optional)

**Purpose:** Describes the queue object to open

### 2. **MQMD** - Message Descriptor
```c
MQMD md = {MQMD_DEFAULT};
```

**Fields Used:**
- `Format`: Set to `MQFMT_STRING` (character string format)
- `MsgId`: Reset to `MQMI_NONE` before each `MQPUT` to get a new message ID

**Purpose:** Describes message properties (format, IDs, etc.)

### 3. **MQPMO** - Put Message Options
```c
MQPMO pmo = {MQPMO_DEFAULT};
```

**Fields Used:**
- `Options`: Set to `MQPMO_NO_SYNCPOINT | MQPMO_FAIL_IF_QUIESCING`

**Purpose:** Controls how the message is put (transactional, syncpoint, etc.)

### 4. **MQCNO** - Connection Options
```c
MQCNO cno = {MQCNO_DEFAULT};
```

**Fields Used:**
- Points to `MQCSP` structure if authentication is enabled

**Purpose:** Controls connection behavior (authentication, etc.)

### 5. **MQCSP** - Security Parameters
```c
MQCSP csp = {MQCSP_DEFAULT};
```

**Purpose:** Used for authentication (if `SAMPLE_AUTH_ENABLED` is defined)

### 6. **Handles**
```c
MQHCONN Hcon;  // Connection handle
MQHOBJ  Hobj;  // Object handle
```

**Purpose:** References to MQ objects (queue manager connection, queue object)

### 7. **Buffer**
```c
char buffer[65535];  // Message buffer (max 65534 characters + null)
```

**Purpose:** Stores message data read from stdin

**Size Limitation:** Maximum 65534 characters per line (longer lines are truncated)

---

## Program Flow

### Detailed Step-by-Step Execution:

1. **Initialization**
   - Check for authentication environment variables (`MQSAMP_USER_ID`, `MQSAMP_TOKEN`)
   - Print "Sample AMQSPUT0 start"
   - Validate command-line arguments (require at least queue name)

2. **Authentication Setup** (if enabled)
   - Call `getAuthInfo(&cno, &csp)` to set up authentication
   - Read password/token from terminal if needed

3. **Queue Manager Connection**
   - Extract queue manager name from argv[2] (if provided)
   - Call `MQCONNX()` to connect
   - Handle errors: exit on failure, warn on warning

4. **Queue Name Setup**
   - Copy queue name from argv[1] to `od.ObjectName`
   - Copy target queue manager from argv[5] to `od.ObjectQMgrName` (if provided)
   - Copy dynamic queue name from argv[6] to `od.DynamicQName` (if provided)

5. **Open Options Setup**
   - Extract open options from argv[3] (if provided)
   - Default: `MQOO_OUTPUT | MQOO_FAIL_IF_QUIESCING`

6. **Open Queue**
   - Call `MQOPEN()` with queue name and options
   - Store object handle in `Hobj`
   - Report errors but continue (will fail in message loop if needed)

7. **Message Format Setup**
   - Set `md.Format` to `MQFMT_STRING`
   - Set `pmo.Options` to `MQPMO_NO_SYNCPOINT | MQPMO_FAIL_IF_QUIESCING`

8. **Message Reading Loop**
   - Read lines from stdin using `fgets()`
   - Remove trailing newline character
   - If line is empty or EOF, exit loop
   - For each non-empty line:
     - Reset `md.MsgId` to `MQMI_NONE` (to get new message ID)
     - Call `MQPUT()` with message data
     - Report any reason codes
   - Continue until empty line or `MQCC_FAILED`

9. **Close Queue**
   - Extract close options from argv[4] (if provided)
   - Default: `MQCO_NONE`
   - Call `MQCLOSE()` if queue was successfully opened

10. **Disconnect**
    - Call `MQDISC()` if not already connected
    - Report any reason codes

11. **Termination**
    - Print "Sample AMQSPUT0 end"
    - Return 0 (success)

---

## Message Processing Logic

### Input Reading:
```c
while (CompCode != MQCC_FAILED)
{
    if (fgets(buffer, sizeof(buffer), fp) != NULL)
    {
        messlen = (MQLONG)strlen(buffer);
        if (buffer[messlen-1] == '\n')  // Remove newline
        {
            buffer[messlen-1] = '\0';
            --messlen;
        }
    }
    else messlen = 0;  // EOF = empty line
    
    if (messlen > 0)
    {
        // Reset MsgId for new message
        memcpy(md.MsgId, MQMI_NONE, sizeof(md.MsgId));
        
        // Put message
        MQPUT(...);
    }
    else
        CompCode = MQCC_FAILED;  // Exit loop
}
```

### Key Behaviors:

1. **Newline Removal:** All trailing newline characters (`\n`) are removed from input lines
2. **Empty Line Termination:** An empty line (or EOF) stops the program
3. **Message ID:** Each message gets a new unique message ID (reset to `MQMI_NONE` before each put)
4. **Message Format:** All messages are sent as `MQFMT_STRING` (character string format)
5. **Line Length Limit:** Maximum 65534 characters per line (buffer size - 1)
6. **Non-Transactional:** Messages are sent without syncpoint (`MQPMO_NO_SYNCPOINT`)

### Message Format:
- **Type:** Datagram message (non-persistent by default)
- **Format:** `MQFMT_STRING` (character string)
- **Length:** Variable (up to 65534 characters)
- **Content:** Text from stdin (one line = one message)

---

## Error Handling

### Error Reporting Strategy:

1. **Connection Errors (`MQCONNX`):**
   - **FAILED:** Print reason code and exit with that reason code
   - **WARNING:** Print warning and reason code, continue

2. **Open Errors (`MQOPEN`):**
   - Print reason code if `Reason != MQRC_NONE`
   - If `OpenCode == MQCC_FAILED`: Print error message
   - Continue (will fail in message loop if queue not opened)

3. **Put Errors (`MQPUT`):**
   - Print reason code if `Reason != MQRC_NONE`
   - Continue to next line (doesn't stop on individual message failures)
   - Loop exits when `CompCode == MQCC_FAILED` (set by empty line)

4. **Close Errors (`MQCLOSE`):**
   - Print reason code if `Reason != MQRC_NONE`
   - Continue (queue already closed or closing)

5. **Disconnect Errors (`MQDISC`):**
   - Print reason code if `Reason != MQRC_NONE`
   - Continue (program ending anyway)

### Exit Codes:
- **0:** Success
- **99:** Required parameter (queue name) missing
- **Other:** MQ reason codes (from `MQCONNX` failures)

---

## Authentication Support

### Environment Variables:

1. **`MQSAMP_USER_ID`**
   - If set, user ID authentication is requested
   - Password must be entered at terminal prompt
   - Requires `SAMPLE_AUTH_ENABLED` compile flag

2. **`MQSAMP_TOKEN`**
   - If set, token authentication is requested
   - Token must be entered at terminal prompt
   - Requires `SAMPLE_AUTH_ENABLED` compile flag

### Authentication Flow:
```c
#ifdef SAMPLE_AUTH_ENABLED
    getAuthInfo(&cno, &csp);  // Sets up authentication
#endif
```

**Note:** If authentication environment variables are set but `SAMPLE_AUTH_ENABLED` is not defined, program prints a message but continues without authentication.

### Security Considerations:
- Password is read from terminal (not command line) to avoid exposure
- Password is not stored in process memory longer than necessary
- Uses `MQCSP` structure for secure authentication

---

## Usage Examples

### Example 1: Basic Usage (Default Queue Manager)
```bash
echo "Hello World" | amqsput MY.QUEUE
```

**Output:**
```
Sample AMQSPUT0 start
target queue is MY.QUEUE
Sample AMQSPUT0 end
```

### Example 2: Specify Queue Manager
```bash
echo "Test Message" | amqsput MY.QUEUE MY.QMGR
```

### Example 3: Multiple Messages
```bash
cat <<EOF | amqsput MY.QUEUE MY.QMGR
Message 1
Message 2
Message 3

EOF
```

**Note:** Empty line terminates input

### Example 4: From File
```bash
amqsput MY.QUEUE MY.QMGR < messages.txt
```

### Example 5: With Custom Open Options
```bash
echo "Test" | amqsput MY.QUEUE MY.QMGR 8208
```

### Example 6: Remote Queue
```bash
echo "Remote Message" | amqsput REMOTE.QUEUE MY.QMGR 8208 0 TARGET.QMGR
```

### Example 7: In Shell Script (as used in mq_connection_test.sh)
```bash
printf "%s\n\n" "$test_msg" | amqsput "$target_queue" "$qmgr"
```

**Key Points:**
- `printf "%s\n\n"` adds message + newline + empty line (to terminate)
- Redirect output to `/dev/null` to suppress informational messages
- Check exit code (`$?`) to verify success

---

## Key Implementation Details

### 1. **Message ID Handling**
```c
memcpy(md.MsgId, MQMI_NONE, sizeof(md.MsgId));
```
- Resets message ID to `MQMI_NONE` before each `MQPUT`
- Causes MQ to generate a new unique message ID automatically
- **Alternative:** Could use `MQPMO_NEW_MSG_ID` option (commented out in code)

### 2. **Newline Character Removal**
```c
if (buffer[messlen-1] == '\n')
{
    buffer[messlen-1] = '\0';
    --messlen;
}
```
- Removes trailing newline from each input line
- Ensures message content doesn't include the newline character
- Message ends with null terminator (not included in message length)

### 3. **Empty Line Detection**
```c
if (messlen > 0)
{
    // Put message
}
else
    CompCode = MQCC_FAILED;  // Exit loop
```
- Empty line (or EOF) sets `CompCode = MQCC_FAILED`
- Loop condition `while (CompCode != MQCC_FAILED)` exits
- This is the normal termination condition

### 4. **Buffer Size Limitation**
- Buffer size: `65535` bytes (char buffer[65535])
- Maximum message length: `65534` characters (one byte reserved for null terminator)
- Longer lines are truncated by `fgets()`

### 5. **Non-Transactional Mode**
```c
pmo.Options = MQPMO_NO_SYNCPOINT | MQPMO_FAIL_IF_QUIESCING;
```
- Messages are sent without syncpoint (non-transactional)
- Each message is committed immediately
- No rollback capability

### 6. **Connection Handle Reuse Check**
```c
if (CReason != MQRC_ALREADY_CONNECTED)
{
    MQDISC(&Hcon, ...);
}
```
- Only disconnects if not already connected
- Prevents double-disconnect errors

### 7. **Default Queue Manager**
```c
QMName[0] = 0;  // default
if (argc > 2)
    strncpy(QMName, argv[2], ...);
```
- Empty string (`QMName[0] = 0`) means default queue manager
- `MQCONNX` with NULL or empty name connects to default

---

## Limitations and Considerations

### 1. **Message Size Limit**
- **Maximum:** 65534 characters per message
- **Reason:** Buffer size limitation
- **Workaround:** Split large messages into multiple lines

### 2. **Non-Persistent Messages**
- Messages are sent as datagram (non-persistent) by default
- Will be lost if queue manager stops before delivery
- **Note:** Persistence is controlled by queue manager, not this program

### 3. **No Transaction Support**
- Uses `MQPMO_NO_SYNCPOINT`
- No rollback capability
- Each message is committed immediately

### 4. **Single Queue Only**
- Can only send to one queue per execution
- Must run multiple times for multiple queues

### 5. **Text Messages Only**
- Format is fixed to `MQFMT_STRING`
- Not suitable for binary data
- Newline characters are stripped

### 6. **No Message Properties**
- Cannot set custom message properties
- Uses default message descriptor values
- Message ID is auto-generated

### 7. **Error Handling**
- Continues on individual message failures
- Only stops on connection/queue open failures
- May send partial messages if errors occur mid-stream

### 8. **Authentication**
- Requires compilation with `SAMPLE_AUTH_ENABLED`
- Password must be entered interactively (not suitable for automation)
- Token authentication available but requires interactive input

### 9. **Platform Dependencies**
- Requires IBM MQ client libraries
- Must be compiled for target platform
- Binary is platform-specific (ELF 64-bit in this case)

### 10. **Performance**
- One `MQPUT` call per line
- Not optimized for high-throughput scenarios
- Suitable for testing and low-volume operations

---

## Comparison with Alternative Methods

### vs. `runmqsc PUT` Command:

| Feature | amqsput | runmqsc PUT |
|---------|---------|-------------|
| **Ease of Use** | Simple stdin input | Requires script file |
| **Message Format** | String only | String only |
| **Multiple Messages** | Easy (one per line) | One per command |
| **Error Handling** | Per-message | Per-command |
| **Performance** | One MQPUT per line | One MQPUT per command |
| **Dependencies** | Requires compiled binary | Uses runmqsc (always available) |

### vs. Custom MQ Application:

| Feature | amqsput | Custom Application |
|---------|---------|-------------------|
| **Flexibility** | Limited | Full control |
| **Message Properties** | Default only | Customizable |
| **Transaction Support** | No | Yes |
| **Binary Data** | No | Yes |
| **Performance** | Basic | Optimizable |
| **Development Time** | None (ready to use) | Requires coding |

---

## Best Practices for Using amqsput

1. **Always Check Exit Code**
   ```bash
   echo "Message" | amqsput QUEUE QMGR
   if [ $? -eq 0 ]; then
       echo "Success"
   else
       echo "Failed"
   fi
   ```

2. **Suppress Output in Scripts**
   ```bash
   echo "Message" | amqsput QUEUE QMGR > /dev/null 2>&1
   ```

3. **Terminate with Empty Line**
   ```bash
   printf "%s\n\n" "$message" | amqsput QUEUE QMGR
   ```

4. **Handle Long Messages**
   - Split messages longer than 65534 characters
   - Or use alternative methods (custom application)

5. **Use for Testing Only**
   - Suitable for testing and development
   - For production, consider custom applications with proper error handling

6. **Verify Message Delivery**
   - Check queue depth after sending
   - Use `amqsget` or `runmqsc DISPLAY QLOCAL CURDEPTH` to verify

---

## Summary

`amqsput` is a simple, effective utility for putting text messages to IBM MQ queues. It demonstrates proper use of MQI calls (`MQCONNX`, `MQOPEN`, `MQPUT`, `MQCLOSE`, `MQDISC`) and provides a reference implementation for MQ application development.

**Key Strengths:**
- ✅ Simple command-line interface
- ✅ Easy integration with scripts
- ✅ Demonstrates proper MQI usage
- ✅ Handles multiple messages efficiently
- ✅ Good error reporting

**Key Limitations:**
- ❌ Message size limited to 65534 characters
- ❌ Text messages only (no binary)
- ❌ No transaction support
- ❌ No custom message properties
- ❌ Authentication requires interactive input

**Use Cases:**
- Testing message delivery
- Quick message sending from scripts
- Learning MQI programming
- Low-volume message operations
- Development and debugging

---

## References

- **Source Code:** `/opt/mqm/samp/amqsput0.c`
- **Binary:** `/opt/mqm/samp/bin/amqsput`
- **IBM MQ Documentation:** Application Programming Reference
- **MQI Reference:** Message Queue Interface documentation
- **Related Programs:** `amqsget` (get messages), `amqsbcg` (browse messages)

---

*Document created: 2025*
*Based on IBM MQ Sample Program amqsput0.c (Copyright IBM Corp. 1994-2024)*

