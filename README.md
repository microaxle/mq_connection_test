# IBM MQ Connection Test Script

This script automatically discovers related IBM MQ objects and sends a test message to verify connectivity.

## Features

- Auto-discovers transmission queue (XMITQ) from the given queue
- Discovers sender channel (SDR) associated with the transmission queue
- Discovers target queue manager
- Discovers receiver channel (RCVR) on target queue manager
- Checks the state of all discovered objects
- Sends a test message if all checks pass

## Usage

```bash
./mq_test.sh <queue_manager_name> <queue_name>
```

### Example

```bash
./mq_test.sh APEX.C1.MEM1 APEX.TO.OMNI.WIRE.REQ
```

## Prerequisites

- IBM MQ must be installed on the server
- The script must be run on the server where the queue manager is located
- User must have appropriate MQ permissions to:
  - Display queue manager status
  - Display queue definitions
  - Display channel definitions and status
  - Put messages to queues

## Required MQ Commands

The script uses the following IBM MQ commands:
- `dspmq` - Display queue manager information
- `runmqsc` - Run MQSC commands
- `amqsput` or `dmpmqmsg` - Send messages (one of these should be available)

## Output

The script provides colored output:
- **Blue [INFO]**: Informational messages
- **Green [SUCCESS]**: Successful operations
- **Yellow [WARNING]**: Warnings (non-critical issues)
- **Red [ERROR]**: Errors (critical failures)

## How It Works

1. **Queue Manager Check**: Verifies the source queue manager exists and is running
2. **Transmission Queue Discovery**: Queries the queue definition to find the XMITQ attribute
3. **Sender Channel Discovery**: Finds the sender channel that uses the discovered transmission queue
4. **Target Queue Manager Discovery**: Extracts target queue manager information from the channel definition
5. **Receiver Channel Discovery**: Attempts to find the receiver channel on the target queue manager
6. **Test Message**: Sends a test message with timestamp to verify end-to-end connectivity

## Notes

- If the queue is a local queue (no XMITQ), the script will warn but continue
- Remote queue manager status may not be verifiable if not accessible
- The script will attempt multiple methods to send test messages for compatibility

