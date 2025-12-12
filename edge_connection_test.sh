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
            ping_output=$(echo "$ping_result" | grep -oE "AMQ[0-9]+[EI].*" | head -1 | sed 's/^[[:space:]]*//')
            [ -z "$ping_output" ] && ping_output="No ping response"
            sender_status="Inactive, $ping_output"
        else
            chstate=$(echo "$chstatus" | grep -o "STATE([^)]*)" | sed 's/STATE(\(.*\))/\1/' | head -1)
            if echo "$chstate" | grep -qiE "^RUNNING$|^ACTIVE$"; then
                sender_status="Running"
            else
                ping_result=$(echo "PING CHL('$sender_channel')" | runmqsc "$source_qmgr" 2>&1)
                ping_output=$(echo "$ping_result" | grep -oE "AMQ[0-9]+[EI].*" | head -1 | sed 's/^[[:space:]]*//')
                [ -z "$ping_output" ] && ping_output="No ping response"
                sender_status="$chstate, $ping_output"
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
    echo "Sending test message..."
    depth_before="$xmitq_depth"
    
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
    else
        echo "Error: Failed to send test message"
        exit 1
    fi
fi
