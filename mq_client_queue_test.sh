#!/bin/bash

source_qmgr=$1
target_queue=$2
qm_alias=$3

if [ -z "$source_qmgr" ] || [ -z "$target_queue" ] || [ -z "$qm_alias" ]; then
    echo "Usage: $0 <source_qmgr> <target_queue> <qm_alias>"
    exit 1
fi

# Step 1: Get QMALIAS attributes
targqmgr=$(echo "DISPLAY QMALIAS('$qm_alias') TARGQMGR" | runmqsc "$source_qmgr" 2>/dev/null | \
    grep "^   TARGQMGR(" | sed 's/.*TARGQMGR(\([^)]*\)).*/\1/' | head -1)

xmitq=$(echo "DISPLAY QMALIAS('$qm_alias') XMITQ" | runmqsc "$source_qmgr" 2>/dev/null | \
    grep -i "^   XMITQ(" | sed 's/.*XMITQ(\([^)]*\)).*/\1/' | head -1)
[ -z "$xmitq" ] && xmitq="$qm_alias"

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
connname=""
if [ -n "$xmitq" ]; then
    sender_channel=$(echo "DISPLAY CHANNEL(*) XMITQ" | runmqsc "$source_qmgr" 2>/dev/null | \
        grep -B2 "XMITQ($xmitq)" | grep "^   CHANNEL(" | \
        sed 's/.*CHANNEL(\([^)]*\)).*/\1/' | head -1)
    
    if [ -n "$sender_channel" ]; then
        connname=$(echo "DISPLAY CHANNEL('$sender_channel') CONNAME" | runmqsc "$source_qmgr" 2>/dev/null | \
            grep "^   CONNAME(" | sed 's/.*CONNAME(\([^)]*\)).*/\1/' | head -1)
        
        chstatus=$(echo "DISPLAY CHSTATUS('$sender_channel')" | runmqsc "$source_qmgr" 2>&1)
        
        if echo "$chstatus" | grep -qiE "Channel Status not found|AMQ8420I"; then
            ping_result=$(echo "PING CHL('$sender_channel')" | runmqsc "$source_qmgr" 2>&1)
            if echo "$ping_result" | grep -qiE "AMQ9501I|AMQ9514E|in use|ping successful"; then
                sender_status="Channel is inactive but ping is good"
            else
                sender_status="Channel is inactive, ping failed"
            fi
        else
            chstate=$(echo "$chstatus" | grep -o "STATE([^)]*)" | sed 's/STATE(\(.*\))/\1/' | head -1)
            if echo "$chstate" | grep -qiE "^RUNNING$|^ACTIVE$"; then
                sender_status="Channel is running"
            else
                ping_result=$(echo "PING CHL('$sender_channel')" | runmqsc "$source_qmgr" 2>&1)
                if echo "$ping_result" | grep -qiE "AMQ9501I|AMQ9514E|in use|ping successful"; then
                    sender_status="Channel is retrying, ping result: GOOD"
                else
                    sender_status="Channel is retrying, ping result: FAILED"
                fi
            fi
        fi
    fi
fi

# Display summary
echo ""
echo "=================================================================================="
echo "                    QUEUE MANAGER ALIAS ROUTING DISCOVERY SUMMARY"
echo "=================================================================================="
printf "%-25s %s\n" "Target Queue:" "$target_queue"
printf "%-25s %s\n" "Source QMgr:" "$source_qmgr"
printf "%-25s %s\n" "QM Alias:" "$qm_alias"
printf "%-25s %s\n" "Actual Target QMgr:" "${targqmgr:-Not found}"
printf "%-25s %s\n" "amqsput Options:" "openOptions=8208, closeOptions=0"
printf "%-25s %s\n" "Connection Name:" "${connname:-Not found}"
printf "%-25s %s\n" "Transmission Queue:" "${xmitq:-Not found} (Depth: $xmitq_depth)"
printf "%-25s %s\n" "Sender Channel:" "${sender_channel:-Not found}"
[ -n "$sender_channel" ] && printf "%-25s %s\n" "Sender Channel Status:" "$sender_status"
echo "=================================================================================="
echo ""
