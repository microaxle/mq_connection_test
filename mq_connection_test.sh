#!/bin/bash

################################################################################
# IBM MQ Connection Test Script
# 
# Purpose: Auto-discovers related MQ objects and sends a test message
# 
# Usage: ./mq_test.sh <queue_manager_name> <queue_name>
# Example: ./mq_test.sh APEX.C1.MEM1 APEX.TO.OMNI.WIRE.REQ
#
# Requirements:
#   - IBM MQ must be installed on the server
#   - Script must run on server where queue manager is located
#   - User must have MQ permissions to display objects and put messages
################################################################################

# ============================================================================
# CONFIGURATION
# ============================================================================

# Color codes for terminal output (ANSI escape sequences)
RED='\033[0;31m'      # Red color for errors
GREEN='\033[0;32m'    # Green color for success
YELLOW='\033[1;33m'   # Yellow color for warnings
BLUE='\033[0;34m'     # Blue color for info
NC='\033[0m'          # No color (reset)

# Quiet mode: suppress verbose output, only show summary table
QUIET_MODE=true

# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================

# Function: Print informational message (blue)
# Usage: print_info "message text"
print_info() {
    [ "$QUIET_MODE" != "true" ] && echo -e "${BLUE}[INFO]${NC} $1" >&2
}

# Function: Print success message (green)
# Usage: print_success "message text"
print_success() {
    [ "$QUIET_MODE" != "true" ] && echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

# Function: Print warning message (yellow)
# Usage: print_warning "message text"
print_warning() {
    [ "$QUIET_MODE" != "true" ] && echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

# Function: Print error message (red) - always shown even in quiet mode
# Usage: print_error "message text"
print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# ============================================================================
# QUEUE MANAGER FUNCTIONS
# ============================================================================

# Function: Check if queue manager exists and is running
# Parameters: $1 = queue manager name
# Returns: 0 if running, 1 if not found or not running
check_qmgr() {
    local qmgr=$1  # Store queue manager name in local variable
    
    print_info "Checking queue manager: $qmgr"
    
    # Check if queue manager exists using dspmq command
    # Redirect output to /dev/null to suppress normal output, check exit code
    if ! dspmq -m "$qmgr" > /dev/null 2>&1; then
        print_error "Queue manager '$qmgr' not found"
        return 1  # Return error code
    fi
    
    # Get queue manager status from dspmq output
    # Parse STATUS(value) from output using sed
    local status=$(dspmq -m "$qmgr" | sed -n 's/.*STATUS(\([^)]*\)).*/\1/p')
    
    # Check if status contains "Running" (case insensitive)
    if echo "$status" | grep -qi "running"; then
        print_success "Queue manager '$qmgr' is Running"
        [ "$QUIET_MODE" != "true" ] && echo "  Status: $status" >&2
        return 0  # Return success
    else
        print_error "Queue manager '$qmgr' is not Running. Status: $status"
        return 1  # Return error
    fi
}

# ============================================================================
# QUEUE DISCOVERY FUNCTIONS
# ============================================================================

# Function: Discover transmission queue (XMITQ) from a queue
# Parameters: $1 = queue manager name, $2 = queue name
# Returns: "xmitq_name|depth" on success, empty on failure
discover_xmitq() {
    local qmgr=$1      # Queue manager name
    local queue=$2     # Queue name to check
    local xmitq=""     # Transmission queue name (to be discovered)
    
    print_info "Discovering transmission queue for queue: $queue"
    
    # First, try to check if it's a remote queue
    # DISPLAY QREMOTE command shows remote queue definition
    local qtype=$(echo "DISPLAY QREMOTE('$queue')" | runmqsc "$qmgr" 2>/dev/null | \
        grep -i "TYPE(QREMOTE)" | head -1)
    
    if [ -n "$qtype" ]; then
        # It's a remote queue - get XMITQ attribute from remote queue definition
        xmitq=$(echo "DISPLAY QREMOTE('$queue') XMITQ" | runmqsc "$qmgr" 2>/dev/null | \
            grep -i "^   XMITQ(" | sed 's/.*XMITQ(\([^)]*\)).*/\1/' | head -1)
    else
        # Try as local queue - some local queues may have XMITQ set
        xmitq=$(echo "DISPLAY QLOCAL('$queue') XMITQ" | runmqsc "$qmgr" 2>/dev/null | \
            grep -i "^   XMITQ(" | sed 's/.*XMITQ(\([^)]*\)).*/\1/' | head -1)
    fi
    
    # Check if transmission queue was found
    if [ -z "$xmitq" ] || [ "$xmitq" == " " ]; then
        print_warning "No transmission queue found for queue '$queue' (may be a local queue)"
        return 1
    fi
    
    print_success "Found transmission queue: $xmitq"
    
    # Get current depth of transmission queue (number of messages waiting)
    # CURDEPTH shows how many messages are currently in the queue
    local qstate=$(echo "DISPLAY QLOCAL('$xmitq') CURDEPTH" | runmqsc "$qmgr" 2>/dev/null | \
        grep -i "^   CURDEPTH(" | sed 's/.*CURDEPTH(\([^)]*\)).*/\1/' | head -1)
    local xmitq_depth=${qstate:-0}  # Default to 0 if not found
    
    [ "$QUIET_MODE" != "true" ] && echo "  Transmission Queue: $xmitq" >&2
    [ "$QUIET_MODE" != "true" ] && echo "  Current Depth: $xmitq_depth" >&2
    
    # Verify transmission queue actually exists
    if echo "DISPLAY QLOCAL('$xmitq')" | runmqsc "$qmgr" > /dev/null 2>&1; then
        print_success "Transmission queue '$xmitq' exists"
        # Return queue name and depth separated by pipe for parsing
        echo "$xmitq|$xmitq_depth"
        return 0
    else
        print_error "Transmission queue '$xmitq' does not exist"
        return 1
    fi
}

# Function: Get current depth of a queue
# Parameters: $1 = queue manager, $2 = queue name
# Returns: queue depth (number of messages)
get_queue_depth() {
    local qmgr=$1
    local queue=$2
    local target_queue="$queue"  # Default to the queue itself
    
    # Check if it's a remote queue - if so, check transmission queue depth instead
    local qtype=$(echo "DISPLAY QREMOTE('$queue')" | runmqsc "$qmgr" 2>/dev/null | \
        grep -i "TYPE(QREMOTE)" | head -1)
    
    if [ -n "$qtype" ]; then
        # It's a remote queue - get the transmission queue name
        local xmitq=$(echo "DISPLAY QREMOTE('$queue') XMITQ" | runmqsc "$qmgr" 2>/dev/null | \
            grep -i "^   XMITQ(" | sed 's/.*XMITQ(\([^)]*\)).*/\1/' | head -1)
        if [ -n "$xmitq" ]; then
            target_queue="$xmitq"  # Use transmission queue
        fi
    fi
    
    # Get current depth of the target queue
    local depth=$(echo "DISPLAY QLOCAL('$target_queue') CURDEPTH" | runmqsc "$qmgr" 2>/dev/null | \
        grep -i "^   CURDEPTH(" | sed 's/.*CURDEPTH(\([^)]*\)).*/\1/' | head -1)
    
    # Return depth, default to 0 if not found
    echo "${depth:-0}"
}

# ============================================================================
# CHANNEL FUNCTIONS
# ============================================================================

# Function: Ping a channel using MQ PING CHL command
# Parameters: $1 = queue manager, $2 = channel name, $3 = channel type (SDR/RCVR)
# Returns: 0 if ping successful, 1 if failed
# Strategy: Use IBM MQ native PING CHL command to check channel connectivity
ping_channel() {
    local qmgr=$1
    local channel=$2
    local channel_type=$3  # SDR (sender) or RCVR (receiver) - not used but kept for compatibility
    
    print_info "Pinging channel '$channel' using MQ PING CHL command..."
    
    # Use IBM MQ native PING CHL command
    # This command checks if the channel can be reached/connected
    local ping_output=$(echo "PING CHL('$channel')" | runmqsc "$qmgr" 2>&1)
    
    # Check for success indicators:
    # 1. "Channel is in use" (AMQ9514E) - means channel exists and is active (good!)
    # 2. Success messages (AMQ9xxxI)
    # 3. "One MQSC command read" without syntax errors
    
    # "Channel is in use" is actually a good sign - channel exists and is active
    if echo "$ping_output" | grep -qiE "AMQ9514E.*in use|Channel.*is in use"; then
        print_success "Channel '$channel' ping successful (channel is in use/active)"
        return 0
    fi
    
    # Check for explicit error messages that indicate channel doesn't exist or can't be pinged
    if echo "$ping_output" | grep -qiE "AMQ8144E.*not found|AMQ8145E|Channel.*not found|AMQ.*E.*not found"; then
        print_warning "Channel '$channel' ping failed (channel not found)"
        return 1
    fi
    
    # Check for other error messages
    if echo "$ping_output" | grep -qiE "AMQ[0-9]+E"; then
        # Check if it's a critical error (not just "in use")
        if ! echo "$ping_output" | grep -qiE "in use|successfully"; then
            print_warning "Channel '$channel' ping failed"
            return 1
        fi
    fi
    
    # If we get here, assume ping was successful
    # Some MQ versions may return success without explicit messages
    print_success "Channel '$channel' ping successful"
    return 0
}

# Function: Discover sender channel associated with a transmission queue
# Parameters: $1 = queue manager, $2 = transmission queue name
# Returns: "channel_name|ping_result" on success
discover_sender_channel() {
    local qmgr=$1
    local xmitq=$2
    local ping_result=""  # Result of ping operation
    
    print_info "Discovering sender channel for transmission queue: $xmitq"
    
    # Find sender channel that uses this transmission queue
    # DISPLAY CHANNEL(*) XMITQ shows all channels with their XMITQ attribute
    local channel=$(echo "DISPLAY CHANNEL(*) XMITQ" | runmqsc "$qmgr" 2>/dev/null | \
        grep -B2 "XMITQ($xmitq)" | grep "^   CHANNEL(" | \
        sed 's/.*CHANNEL(\([^)]*\)).*/\1/' | head -1)
    
    # If not found, try alternative: look for any sender channel
    if [ -z "$channel" ]; then
        channel=$(echo "DISPLAY CHANNEL(*) CHLTYPE(SDR)" | runmqsc "$qmgr" 2>/dev/null | \
            grep "^   CHANNEL(" | sed 's/.*CHANNEL(\([^)]*\)).*/\1/' | head -1)
    fi
    
    if [ -z "$channel" ]; then
        print_warning "No sender channel found for transmission queue '$xmitq'"
        return 1
    fi
    
    print_success "Found sender channel: $channel"
    
    # Check channel status to see if it's active
    local chstatus_output=$(echo "DISPLAY CHSTATUS('$channel')" | runmqsc "$qmgr" 2>&1)
    local chstatus=""  # Channel status
    local chstate=""   # Channel state
    
    # Check if channel status exists (channel is active)
    if echo "$chstatus_output" | grep -q "Channel Status not found\|AMQ8420I"; then
        # Channel is not active - ping it to check configuration
        chstatus="NOT ACTIVE"
        chstate="NOT ACTIVE"
        if ping_channel "$qmgr" "$channel" "SDR"; then
            ping_result="GOOD"
        else
            ping_result="FAILED"
        fi
    else
        # Channel is active - parse status and state from output
        # Extract STATUS and STATE from MQSC output (exclude command lines)
        chstatus=$(echo "$chstatus_output" | grep "^   " | grep -v "'$channel'" | \
            grep -o "STATUS([^)]*)" | tail -1 | sed 's/STATUS(\(.*\))/\1/')
        chstate=$(echo "$chstatus_output" | grep "^   " | grep -v "'$channel'" | \
            grep -o "STATE([^)]*)" | tail -1 | sed 's/STATE(\(.*\))/\1/')
        # If STATE not found, try SUBSTATE
        if [ -z "$chstate" ]; then
            chstate=$(echo "$chstatus_output" | grep "^   " | grep -v "'$channel'" | \
                grep -o "SUBSTATE([^)]*)" | tail -1 | sed 's/SUBSTATE(\(.*\))/\1/')
        fi
        ping_result="N/A"  # No ping needed if channel is active
    fi
    
    [ "$QUIET_MODE" != "true" ] && echo "  Channel Name: $channel" >&2
    [ "$QUIET_MODE" != "true" ] && echo "  Status: ${chstatus:-NOT FOUND}" >&2
    [ "$QUIET_MODE" != "true" ] && echo "  State: ${chstate:-NOT FOUND}" >&2
    [ -n "$ping_result" ] && [ "$ping_result" != "N/A" ] && \
        [ "$QUIET_MODE" != "true" ] && echo "  Ping Result: $ping_result" >&2
    
    # Determine if channel is running based on state
    local channel_state="INACTIVE"
    if [ -n "$chstate" ] && [ "$chstate" != "NOT ACTIVE" ] && [ "$chstate" != "NOT FOUND" ]; then
        channel_state="RUNNING"
    fi
    
    # Return channel name, ping result, and state
    echo "$channel|$ping_result|$channel_state"
    return 0
}

# Function: Discover target queue manager from channel or remote queue
# Parameters: $1 = source queue manager, $2 = sender channel, $3 = queue name
# Returns: target queue manager name
discover_target_qmgr() {
    local qmgr=$1
    local channel=$2
    local queue=$3
    local targetqmgr=""
    
    print_info "Discovering target queue manager for channel: $channel"
    
    # First try to get target queue manager from remote queue definition (RQMNAME)
    if [ -n "$queue" ]; then
        targetqmgr=$(echo "DISPLAY QREMOTE('$queue') RQMNAME" | runmqsc "$qmgr" 2>/dev/null | \
            grep "^   RQMNAME(" | sed 's/.*RQMNAME(\([^)]*\)).*/\1/' | head -1)
    fi
    
    # Get connection name from channel (for display purposes)
    local connname=$(echo "DISPLAY CHANNEL('$channel') CONNAME" | runmqsc "$qmgr" 2>/dev/null | \
        grep "^   CONNAME(" | sed 's/.*CONNAME(//; s/)$//' | head -1)
    
    # If not found from queue, try to get from channel definition (TARGQMGR)
    if [ -z "$targetqmgr" ]; then
        targetqmgr=$(echo "DISPLAY CHANNEL('$channel')" | runmqsc "$qmgr" 2>/dev/null | \
            grep "^   TARGQMGR(" | sed 's/.*TARGQMGR(\([^)]*\)).*/\1/' | head -1)
    fi
    
    if [ -z "$targetqmgr" ]; then
        print_warning "Target queue manager not explicitly defined in channel '$channel'"
        [ "$QUIET_MODE" != "true" ] && print_info "Connection Name: ${connname:-NOT FOUND}"
        return 1
    fi
    
    print_success "Found target queue manager: $targetqmgr"
    [ "$QUIET_MODE" != "true" ] && echo "  Target QMgr: $targetqmgr" >&2
    [ "$QUIET_MODE" != "true" ] && echo "  Connection: ${connname:-NOT FOUND}" >&2
    
    # Check target queue manager status if accessible (may be remote)
    if dspmq -m "$targetqmgr" > /dev/null 2>&1; then
        local target_status=$(dspmq -m "$targetqmgr" | sed -n 's/.*STATUS(\([^)]*\)).*/\1/p')
        if echo "$target_status" | grep -qi "running"; then
            print_success "Target queue manager '$targetqmgr' is Running"
        else
            print_warning "Target queue manager '$targetqmgr' status: $target_status"
        fi
    else
        print_warning "Cannot verify target queue manager '$targetqmgr' status (may be remote)"
    fi
    
    echo "$targetqmgr"
    return 0
}

# Function: Discover receiver channel on target queue manager
# Parameters: $1 = target queue manager, $2 = sender channel name
# Returns: "channel_name|ping_result" on success
discover_receiver_channel() {
    local targetqmgr=$1
    local sender_channel=$2
    local ping_result=""
    
    print_info "Discovering receiver channel on target queue manager: $targetqmgr"
    
    # Try to find receiver channel with same name as sender (common pattern)
    local rcvr_channel=$(echo "DISPLAY CHANNEL('$sender_channel') CHLTYPE(RCVR)" | \
        runmqsc "$targetqmgr" 2>/dev/null 2>&1 | grep "^   CHANNEL(" | \
        sed 's/.*CHANNEL(\([^)]*\)).*/\1/' | head -1)
    
    # If not found, try to list all receiver channels and get first one
    if [ -z "$rcvr_channel" ]; then
        rcvr_channel=$(echo "DISPLAY CHANNEL(*) CHLTYPE(RCVR)" | runmqsc "$targetqmgr" 2>/dev/null | \
            grep "^   CHANNEL(" | sed 's/.*CHANNEL(\([^)]*\)).*/\1/' | head -1)
    fi
    
    if [ -z "$rcvr_channel" ]; then
        print_warning "Cannot discover receiver channel on '$targetqmgr' (may require remote access)"
        return 1
    fi
    
    print_success "Found receiver channel: $rcvr_channel"
    
    # Check receiver channel status
    local chstatus_output=$(echo "DISPLAY CHSTATUS('$rcvr_channel')" | runmqsc "$targetqmgr" 2>&1)
    local chstatus=""
    local chstate=""
    
    # Check if channel status exists
    if echo "$chstatus_output" | grep -q "Channel Status not found\|AMQ8420I"; then
        # Channel not active - ping it
        chstatus="NOT ACTIVE"
        chstate="NOT ACTIVE"
        if ping_channel "$targetqmgr" "$rcvr_channel" "RCVR"; then
            ping_result="GOOD"
        else
            ping_result="FAILED"
        fi
    else
        # Channel is active - parse status
        chstatus=$(echo "$chstatus_output" | grep "^   " | grep -v "'$rcvr_channel'" | \
            grep -o "STATUS([^)]*)" | tail -1 | sed 's/STATUS(\(.*\))/\1/')
        chstate=$(echo "$chstatus_output" | grep "^   " | grep -v "'$rcvr_channel'" | \
            grep -o "STATE([^)]*)" | tail -1 | sed 's/STATE(\(.*\))/\1/')
        if [ -z "$chstate" ]; then
            chstate=$(echo "$chstatus_output" | grep "^   " | grep -v "'$rcvr_channel'" | \
                grep -o "SUBSTATE([^)]*)" | tail -1 | sed 's/SUBSTATE(\(.*\))/\1/')
        fi
        ping_result="N/A"
    fi
    
    [ "$QUIET_MODE" != "true" ] && echo "  Receiver Channel: $rcvr_channel" >&2
    [ "$QUIET_MODE" != "true" ] && echo "  Status: ${chstatus:-NOT FOUND}" >&2
    [ "$QUIET_MODE" != "true" ] && echo "  State: ${chstate:-NOT FOUND}" >&2
    [ -n "$ping_result" ] && [ "$ping_result" != "N/A" ] && \
        [ "$QUIET_MODE" != "true" ] && echo "  Ping Result: $ping_result" >&2
    
    # Determine if channel is running based on state
    local channel_state="INACTIVE"
    if [ -n "$chstate" ] && [ "$chstate" != "NOT ACTIVE" ] && [ "$chstate" != "NOT FOUND" ]; then
        channel_state="RUNNING"
    fi
    
    # Return channel name, ping result, and state
    echo "$rcvr_channel|$ping_result|$channel_state"
    return 0
}

# ============================================================================
# MESSAGE SENDING FUNCTIONS
# ============================================================================

# Function: Send test message to queue and verify it was sent
# Parameters: $1 = queue manager, $2 = queue name, $3 = transmission queue name
# Returns: "message|method|status" on success
send_test_message() {
    local qmgr=$1
    local queue=$2
    local xmitq=$3
    local target_queue="$queue"  # Default to sending to the queue itself
    
    print_info "Sending test message to queue: $queue"
    
    # For remote queues, send directly to transmission queue
    if [ -n "$xmitq" ]; then
        target_queue="$xmitq"
    fi
    
    # Get queue depth before sending (to verify message was added)
    local depth_before=$(get_queue_depth "$qmgr" "$queue")
    
    # Create test message with unique identifier and timestamp
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local test_msg="MQ_TEST_MSG|$timestamp|Queue:$queue|QMgr:$qmgr"
    
    local msg_sent=false  # Flag to track if message was sent
    local send_method=""  # Method used to send message
    
    # Try to find amqsput utility (dynamic path discovery)
    # Check common locations for amqsput
    local amqsput_cmd=""
    if [ -f "/opt/mqm/samp/bin/amqsput" ]; then
        amqsput_cmd="/opt/mqm/samp/bin/amqsput"
    elif [ -f "/usr/mqm/samp/bin/amqsput" ]; then
        amqsput_cmd="/usr/mqm/samp/bin/amqsput"
    elif command -v amqsput > /dev/null 2>&1; then
        amqsput_cmd="amqsput"
    fi
    
    # Try amqsput first (most reliable method)
    if [ -n "$amqsput_cmd" ]; then
        # amqsput expects: queue_name queue_manager as arguments
        # Then message on stdin, followed by empty line to end
        printf "%s\n\n" "$test_msg" | "$amqsput_cmd" "$target_queue" "$qmgr" > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            msg_sent=true
            send_method="amqsput"
        fi
    fi
    
    # Fallback: Use runmqsc with PUT command
    if [ "$msg_sent" != "true" ]; then
        local temp_script=$(mktemp)  # Create temporary script file
        # Write MQSC PUT command to temp file
        cat > "$temp_script" << EOF
PUT '$target_queue'
$test_msg
EOF
        # Execute MQSC script
        local put_output=$(runmqsc "$qmgr" < "$temp_script" 2>&1)
        # Check if PUT was successful (look for success indicators)
        if echo "$put_output" | grep -qi "AMQ.*put\|successfully\|One MQSC command read"; then
            msg_sent=true
            send_method="runmqsc"
        fi
        rm -f "$temp_script"  # Clean up temp file
    fi
    
    if [ "$msg_sent" = "true" ]; then
        # Wait a moment for message to be processed
        sleep 2
        # Get queue depth after sending
        local depth_after=$(get_queue_depth "$qmgr" "$queue")
        
        # Verify message was actually sent by checking depth increase
        if [ "$depth_after" -gt "$depth_before" ]; then
            print_success "Test message sent and verified (queue depth: $depth_before -> $depth_after)"
            echo "$test_msg|$send_method|VERIFIED"
            return 0
        elif [ "$depth_after" -eq "$depth_before" ] && [ "$depth_after" -gt 0 ]; then
            # Message might already be in queue or was consumed immediately
            print_success "Test message sent (queue depth: $depth_after)"
            echo "$test_msg|$send_method|SENT"
            return 0
        else
            # Message might have been consumed/transmitted immediately
            print_success "Test message sent (may have been consumed/transmitted)"
            echo "$test_msg|$send_method|SENT"
            return 0
        fi
    else
        print_error "Failed to send test message. Please check MQ utilities availability."
        echo "FAILED|FAILED|FAILED"
        return 1
    fi
}

# ============================================================================
# MAIN FUNCTION
# ============================================================================

# Function: Main execution function
# Parameters: Command line arguments
main() {
    local send_test_msg=false  # Flag to control test message sending
    local qmgr=""              # Queue manager name
    local queue=""             # Queue name
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -s|--send)
                # Enable test message sending
                send_test_msg=true
                shift
                ;;
            -h|--help)
                # Show usage help
                echo "Usage: $0 [OPTIONS] <queue_manager_name> <queue_name>"
                echo ""
                echo "Options:"
                echo "  -s, --send    Send test message after discovery (default: disabled)"
                echo "  -h, --help    Show this help message"
                echo ""
                echo "Examples:"
                echo "  $0 APEX.C1.MEM1 APEX.TO.OMNI.WIRE.REQ"
                echo "  $0 -s APEX.C1.MEM1 APEX.TO.OMNI.WIRE.REQ"
                exit 0
                ;;
            -*)
                # Unknown option
                echo "Error: Unknown option '$1'"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
            *)
                # Positional arguments (queue manager and queue name)
                if [ -z "$qmgr" ]; then
                    qmgr="$1"
                elif [ -z "$queue" ]; then
                    queue="$1"
                else
                    echo "Error: Too many arguments"
                    echo "Use -h or --help for usage information"
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Check if required arguments are provided
    if [ -z "$qmgr" ] || [ -z "$queue" ]; then
        echo "Error: Queue manager name and queue name are required"
        echo "Usage: $0 [OPTIONS] <queue_manager_name> <queue_name>"
        echo "Use -h or --help for more information"
        exit 1
    fi
    
    # Step 1: Check source queue manager exists and is running
    if ! check_qmgr "$qmgr" > /dev/null 2>&1; then
        print_error "Source queue manager check failed. Exiting."
        exit 1
    fi
    
    # Step 2: Discover transmission queue
    local xmitq=""              # Transmission queue name
    local xmitq_depth=""        # Transmission queue depth
    local xmitq_result=$(discover_xmitq "$qmgr" "$queue" 2>/dev/null || echo "")
    if [ -n "$xmitq_result" ]; then
        # Parse result: format is "xmitq_name|depth"
        xmitq=$(echo "$xmitq_result" | cut -d'|' -f1)
        xmitq_depth=$(echo "$xmitq_result" | cut -d'|' -f2)
    fi
    
    # Step 3: Discover sender channel
    local sender_channel=""         # Sender channel name
    local sender_channel_ping=""     # Ping result for sender channel
    local sender_channel_state=""    # Channel state (RUNNING/INACTIVE)
    if [ -n "$xmitq" ]; then
        local sender_result=$(discover_sender_channel "$qmgr" "$xmitq" 2>/dev/null || echo "")
        if [ -n "$sender_result" ]; then
            # Parse result: format is "channel_name|ping_result|state"
            sender_channel=$(echo "$sender_result" | cut -d'|' -f1)
            sender_channel_ping=$(echo "$sender_result" | cut -d'|' -f2)
            sender_channel_state=$(echo "$sender_result" | cut -d'|' -f3)
        fi
    fi
    
    # Step 4: Discover target queue manager and receiver channel
    local targetqmgr=""             # Target queue manager name
    local rcvr_channel=""           # Receiver channel name
    local rcvr_channel_ping=""      # Ping result for receiver channel
    local rcvr_channel_state=""     # Channel state (RUNNING/INACTIVE)
    if [ -n "$sender_channel" ]; then
        # Get target queue manager
        targetqmgr=$(discover_target_qmgr "$qmgr" "$sender_channel" "$queue" 2>/dev/null || echo "")
        if [ -n "$targetqmgr" ]; then
            # Try to discover receiver channel on target queue manager
            local rcvr_result
            rcvr_result=$(discover_receiver_channel "$targetqmgr" "$sender_channel" 2>&1)
            # Extract result from output (last line with pipe separator)
            rcvr_result=$(echo "$rcvr_result" | grep "|" | tail -1)
            if [ -n "$rcvr_result" ] && echo "$rcvr_result" | grep -q "|"; then
                # Parse result: format is "channel_name|ping_result|state"
                rcvr_channel=$(echo "$rcvr_result" | cut -d'|' -f1)
                rcvr_channel_ping=$(echo "$rcvr_result" | cut -d'|' -f2)
                rcvr_channel_state=$(echo "$rcvr_result" | cut -d'|' -f3)
            fi
        fi
    fi
    
    # Step 5: Send test message (only if flag is set)
    local test_msg_result=""        # Result of test message send
    local test_msg_content=""       # Content of test message
    
    if [ "$send_test_msg" = "true" ]; then
        # Send test message only if -s/--send flag is provided
        local test_msg_info=$(send_test_message "$qmgr" "$queue" "$xmitq" 2>/dev/null || \
            echo "FAILED|FAILED|FAILED")
        
        # Parse test message result
        # Format: "message|method|status"
        if echo "$test_msg_info" | grep -q "|" && ! echo "$test_msg_info" | grep -q "^FAILED"; then
            # Extract message content (first 4 fields separated by |)
            test_msg_content=$(echo "$test_msg_info" | cut -d'|' -f1-4)
            # Extract status (6th field)
            local msg_status=$(echo "$test_msg_info" | cut -d'|' -f6)
            if [ "$msg_status" = "VERIFIED" ] || [ "$msg_status" = "SENT" ]; then
                test_msg_result="SUCCESS"
            else
                test_msg_result="FAILED"
            fi
        else
            test_msg_result="FAILED"
        fi
    else
        # Test message sending is disabled
        test_msg_result="SKIPPED"
    fi
    
    # ========================================================================
    # DISPLAY SUMMARY TABLE
    # ========================================================================
    printf "\n"
    printf "================================================================================\n"
    printf "                          DISCOVERY SUMMARY\n"
    printf "================================================================================\n"
    
    # Source Queue Manager
    printf "%-25s %-50s\n" "Source QMgr:" "$qmgr (Running)"
    
    # Queue Name
    printf "%-25s %-50s\n" "Queue:" "$queue"
    
    # Transmission Queue
    if [ -n "$xmitq" ]; then
        printf "%-25s %-50s\n" "Transmission Queue:" "$xmitq (Depth: $xmitq_depth)"
    else
        printf "%-25s %-50s\n" "Transmission Queue:" "Not found"
    fi
    
    # Sender Channel
    if [ -n "$sender_channel" ]; then
        local sender_status="$sender_channel"
        # Check if channel is running
        if [ "$sender_channel_state" == "RUNNING" ]; then
            sender_status="$sender_channel (Running)"
        # Add ping result if channel is inactive
        elif [ -n "$sender_channel_ping" ] && [ "$sender_channel_ping" != "N/A" ]; then
            if [ "$sender_channel_ping" == "GOOD" ]; then
                sender_status="$sender_channel (Inactive, Ping: GOOD)"
            else
                sender_status="$sender_channel (Ping: $sender_channel_ping)"
            fi
        fi
        printf "%-25s %-50s\n" "Sender Channel:" "$sender_status"
    else
        printf "%-25s %-50s\n" "Sender Channel:" "Not found"
    fi
    
    # Target Queue Manager
    if [ -n "$targetqmgr" ]; then
        printf "%-25s %-50s\n" "Target QMgr:" "$targetqmgr"
    else
        printf "%-25s %-50s\n" "Target QMgr:" "Not found"
    fi
    
    # Receiver Channel
    if [ -n "$rcvr_channel" ]; then
        local rcvr_status="$rcvr_channel"
        # Check if channel is running
        if [ "$rcvr_channel_state" == "RUNNING" ]; then
            rcvr_status="$rcvr_channel (Running)"
        # Add ping result if channel is inactive
        elif [ -n "$rcvr_channel_ping" ] && [ "$rcvr_channel_ping" != "N/A" ]; then
            if [ "$rcvr_channel_ping" == "GOOD" ]; then
                rcvr_status="$rcvr_channel (Inactive, Ping: GOOD)"
            else
                rcvr_status="$rcvr_channel (Ping: $rcvr_channel_ping)"
            fi
        fi
        printf "%-25s %-50s\n" "Receiver Channel:" "$rcvr_status"
    else
        printf "%-25s %-50s\n" "Receiver Channel:" "Not found"
    fi
    
    # Test Message Result
    if [ "$test_msg_result" = "SUCCESS" ]; then
        printf "%-25s %-50s\n" "Test Message:" "SUCCESS"
        # Show message content if available
        if [ -n "$test_msg_content" ]; then
            printf "%-25s %-50s\n" "Message Content:" "$test_msg_content"
        fi
    elif [ "$test_msg_result" = "SKIPPED" ]; then
        printf "%-25s %-50s\n" "Test Message:" "SKIPPED (use -s flag to send)"
    else
        printf "%-25s %-50s\n" "Test Message:" "FAILED"
    fi
    
    printf "================================================================================\n"
    printf "\n"
    
    # Exit with appropriate code
    # Exit 0 for success or skipped, exit 1 only for failures
    if [ "$test_msg_result" = "FAILED" ]; then
        exit 1
    else
        exit 0
    fi
}

# ============================================================================
# SCRIPT EXECUTION
# ============================================================================

# Execute main function with all command line arguments
main "$@"
