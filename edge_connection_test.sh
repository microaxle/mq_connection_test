#!/bin/bash

# Hardcoded amqsput options (these don't change)
AMQSPUT_OPEN_OPTIONS=8208
AMQSPUT_CLOSE_OPTIONS=0

SYNC_MODE=false
CUSTOM_MESSAGE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -s)
            SYNC_MODE=true
            shift
            ;;
        -m)
            if [ -z "$2" ]; then
                echo "Error: -m requires a message value"
                exit 1
            fi
            CUSTOM_MESSAGE="$2"
            SYNC_MODE=true
            shift 2
            ;;
        -*)
            echo "Error: Unknown option '$1'"
            exit 1
            ;;
        *)
            if [ -z "$source_qmgr" ]; then
                source_qmgr="$1"
            elif [ -z "$target_queue" ]; then
                target_queue="$1"
            elif [ -z "$target_qmgr_name" ]; then
                target_qmgr_name="$1"
            else
                echo "Error: Too many arguments"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$source_qmgr" ] || [ -z "$target_queue" ] || [ -z "$target_qmgr_name" ]; then
    echo "Usage: $0 <source_qmgr> <target_queue> <target_qmgr_name> [-s] [-m MESSAGE]"
    exit 1
fi

# Step 1: Get QREMOTE attributes
rqmname=$(echo "DISPLAY QREMOTE('$target_qmgr_name') RQMNAME" | runmqsc "$source_qmgr" 2>/dev/null | \
    grep "^   RQMNAME(" | sed 's/.*RQMNAME(\([^)]*\)).*/\1/' | head -1)

xmitq=$(echo "DISPLAY QREMOTE('$target_qmgr_name') XMITQ" | runmqsc "$source_qmgr" 2>/dev/null | \
    grep -i "^   XMITQ(" | sed 's/.*XMITQ(\([^)]*\)).*/\1/' | head -1)

# Step 2: Get transmission queue depth
xmitq_depth="0"
if [ -n "$xmitq" ]; then
    xmitq_depth=$(echo "DISPLAY QLOCAL('$xmitq') CURDEPTH" | runmqsc "$source_qmgr" 2>/dev/null | \
        grep -i "^   CURDEPTH(" | sed 's/.*CURDEPTH(\([^)]*\)).*/\1/' | head -1)
    [ -z "$xmitq_depth" ] && xmitq_depth="0"
fi

# Step 3: Find sender channel
sender_channel=""
sender_status=""
if [ -n "$xmitq" ]; then
    sender_channel=$(echo "DISPLAY CHANNEL(*) WHERE ( XMITQ EQ '$xmitq' )" | runmqsc "$source_qmgr" 2>/dev/null | \
        grep "^   CHANNEL(" | sed 's/.*CHANNEL(\([^)]*\)).*/\1/' | head -1)
    
    if [ -n "$sender_channel" ]; then
        chstatus=$(echo "DISPLAY CHSTATUS('$sender_channel')" | runmqsc "$source_qmgr" 2>&1)
        
        if echo "$chstatus" | grep -qiE "Channel Status not found|AMQ8420I"; then
            ping_result=$(echo "PING CHL('$sender_channel')" | runmqsc "$source_qmgr" 2>&1)
            ping_output=$(echo "$ping_result" | grep -oE "AMQ[0-9]+[EI][^)]*" | head -1 | sed 's/^[[:space:]]*//')
            [ -z "$ping_output" ] && ping_output="No ping response"
            sender_status="Inactive, $ping_output"
        else
            # Extract STATE more carefully - only from lines that start with spaces (MQSC output format)
            # Filter out the command echo line and channel name line to avoid false matches
            chstate=$(echo "$chstatus" | grep "^   " | grep -v "^   DISPLAY\|^   CHANNEL\|'$sender_channel'" | \
                grep -oE "STATE\([^)]+\)" | sed 's/STATE(\(.*\))/\1/' | head -1 | tr -d ' ')
            # Also check STATUS field which might contain RUNNING
            chstatus_val=$(echo "$chstatus" | grep "^   " | grep -v "^   DISPLAY\|^   CHANNEL\|'$sender_channel'" | \
                grep -oE "STATUS\([^)]+\)" | sed 's/STATUS(\(.*\))/\1/' | head -1 | tr -d ' ')
            
            # Check if channel is running - look at both STATE and STATUS
            # For a RUNNING sender channel, STATE should be RUNNING, not MQGET
            if echo "$chstate" | grep -qiE "^RUNNING$|^ACTIVE$" || \
               echo "$chstatus_val" | grep -qiE "^RUNNING$|^ACTIVE$"; then
                sender_status="Running"
            else
                # Channel is not in RUNNING/ACTIVE state - get ping result for diagnostics
                ping_result=$(echo "PING CHL('$sender_channel')" | runmqsc "$source_qmgr" 2>&1)
                # Extract only AMQ error/info codes, not other text
                ping_output=$(echo "$ping_result" | grep -oE "AMQ[0-9]+[EI][^)]*" | head -1 | sed 's/^[[:space:]]*//')
                [ -z "$ping_output" ] && ping_output="No ping response"
                # Use the actual state value, or status if state is empty
                # Filter out any invalid state values like "MQGET" that shouldn't appear for sender channels
                if [ -n "$chstate" ] && [ "$chstate" != "MQGET" ]; then
                    sender_status="$chstate, $ping_output"
                elif [ -n "$chstatus_val" ] && [ "$chstatus_val" != "MQGET" ]; then
                    sender_status="$chstatus_val, $ping_output"
                else
                    # If we got MQGET or other unexpected value, just show ping result
                    local state_display="${chstate:-${chstatus_val:-Unknown}}"
                    sender_status="State: $state_display, $ping_output"
                fi
            fi
        fi
    fi
fi

# Display summary
echo ""
echo "=================================================================================="
echo "                    QREMOTE ROUTING DISCOVERY SUMMARY"
echo "=================================================================================="
printf "%-25s %s\n" "Source QMgr:" "$source_qmgr"
printf "%-25s %s\n" "Target Queue:" "$target_queue"
printf "%-25s %s\n" "Target QMgr Name:" "$target_qmgr_name"
printf "%-25s %s\n" "Actual Target QMgr:" "${rqmname:-Not found}"
printf "%-25s %s\n" "amqsput Options:" "openOptions=$AMQSPUT_OPEN_OPTIONS, closeOptions=$AMQSPUT_CLOSE_OPTIONS"
printf "%-25s %s\n" "Transmission Queue:" "${xmitq:-Not found} (Depth: $xmitq_depth)"
printf "%-25s %s\n" "Sender Channel:" "${sender_channel:-Not found}"
[ -n "$sender_channel" ] && printf "%-25s %s\n" "Sender Channel Status:" "$sender_status"
echo "=================================================================================="
echo ""

# Send test message if -s or -m flag is set
# Note: Message sending happens AFTER summary table - message content is NOT included in summary
if [ "$SYNC_MODE" = "true" ]; then
    # Find amqsput utility
    amqsput_cmd=""
    if [ -f "/opt/mqm/samp/bin/amqsput" ]; then
        amqsput_cmd="/opt/mqm/samp/bin/amqsput"
    elif [ -f "/usr/mqm/samp/bin/amqsput" ]; then
        amqsput_cmd="/usr/mqm/samp/bin/amqsput"
    elif command -v amqsput > /dev/null 2>&1; then
        amqsput_cmd="amqsput"
    fi
    
    if [ -z "$amqsput_cmd" ]; then
        echo "Error: amqsput utility not found"
        exit 1
    fi
    
    # Create test message - use custom message if provided, otherwise use default
    if [ -n "$CUSTOM_MESSAGE" ]; then
        test_msg="$CUSTOM_MESSAGE"
    else
        test_msg="MQ_TEST_MSG|$(date '+%Y-%m-%d %H:%M:%S')|Queue:$target_queue|QMgr:$source_qmgr"
    fi
    
    # Sync mode: send message and verify delivery
    # This section is separate from the summary table above
    echo ""
    echo "--- Test Message Sending (separate from summary above) ---"
    echo "Sending test message..."
    depth_before="$xmitq_depth"
    
    # Send message (suppress output to avoid confusion)
    printf "%s\n\n" "$test_msg" | "$amqsput_cmd" "$target_queue" "$source_qmgr" $AMQSPUT_OPEN_OPTIONS $AMQSPUT_CLOSE_OPTIONS "$target_qmgr_name" > /dev/null 2>&1
    
    if [ $? -eq 0 ]; then
        sleep 2
        depth_after=$(echo "DISPLAY QLOCAL('$xmitq') CURDEPTH" | runmqsc "$source_qmgr" 2>/dev/null | \
            grep -i "^   CURDEPTH(" | sed 's/.*CURDEPTH(\([^)]*\)).*/\1/' | head -1)
        [ -z "$depth_after" ] && depth_after="0"
        
        if [ "$depth_after" -gt "$depth_before" ]; then
            echo "Test message sent successfully (Transmission Queue Depth: $depth_before -> $depth_after)"
        else
            echo "Test message sent (may have been transmitted immediately)"
        fi
        echo "--- End of Test Message Sending ---"
        echo ""
    else
        echo "Error: Failed to send test message"
        echo "--- End of Test Message Sending ---"
        echo ""
        exit 1
    fi
fi
