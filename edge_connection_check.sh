#!/bin/bash
#===============================================================================
# IBM MQ Edge Connection Test
# Tests connectivity between DTCC BE QMgr and Client QMgr via remote queue
#
# Usage: ./edge_connection_test.sh <DTCC_BE_QMgr> <Client_Queue> <Client_Alias> [-s [MSG]] [-v]
#
# Parameters:
#   DTCC_BE_QMgr  - Source DTCC Backend Queue Manager
#   Client_Queue  - Target queue on client side
#   Client_Alias  - Remote queue definition (QREMOTE) pointing to client
#   -s [MSG]      - Optional: Send test message with optional custom text
#   -v            - Optional: Verbose mode for debugging
#
# Exit Codes: 0 = Success, 1 = Error
#===============================================================================

# Configuration
AMQSPUT_OPTS="8208 0"
MAX_MSG_SIZE=102400

#-------------------------------------------------------------------------------
# Parse command line arguments
#-------------------------------------------------------------------------------
SEND_MSG=false CUSTOM_MSG="" VERBOSE=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -s) SEND_MSG=true; shift
            [[ -n "$1" && ! "$1" =~ ^- ]] && { CUSTOM_MSG="$1"; shift; } ;;
        -v) VERBOSE=true; shift ;;
        -*) echo "Error: Unknown option '$1'"; exit 1 ;;
        *)  [[ -z "$DTCC_QMGR" ]] && DTCC_QMGR="$1" || \
            { [[ -z "$CLIENT_QUEUE" ]] && CLIENT_QUEUE="$1" || \
            { [[ -z "$CLIENT_ALIAS" ]] && CLIENT_ALIAS="$1" || \
            { echo "Error: Too many arguments"; exit 1; }; }; }
            shift ;;
    esac
done

# Validate required arguments
[[ -z "$DTCC_QMGR" || -z "$CLIENT_QUEUE" || -z "$CLIENT_ALIAS" ]] && {
    echo "Usage: $0 <DTCC_BE_QMgr> <Client_Queue> <Client_Alias> [-s [MSG]] [-v]"
    exit 1
}

#-------------------------------------------------------------------------------
# Helper functions
#-------------------------------------------------------------------------------
# Debug logging - only prints when VERBOSE=true
log() { [[ "$VERBOSE" == "true" ]] && echo -e "[DEBUG] $*" >&2; }
log_cmd() { [[ "$VERBOSE" == "true" ]] && echo -e "[MQSC]\n$(echo "$1" | grep -E "AMQ|QUEUE|CHANNEL|QREMOTE|STATUS|CURDEPTH|RQMNAME|XMITQ" | head -15)" >&2; }

# Extract MQSC attribute value: mqsc_val "output" "FIELDNAME"
# Uses word boundary to avoid partial matches (e.g., STATUS vs CHSTATUS)
mqsc_val() { echo "$1" | grep -oE "[[:space:]]$2\([^)]*\)" | sed "s/.*$2(\([^)]*\)).*/\1/" | tr -d ' ' | head -1; }

# Perform channel ping test - returns raw MQSC response
do_ping() {
    log "Executing: PING CHANNEL('$SDR_CHL')"
    local out=$(echo "PING CHANNEL('$SDR_CHL')" | runmqsc "$DTCC_QMGR" 2>&1)
    log_cmd "$out"
    # Return the AMQ message line as-is
    echo "$out" | grep -oE "AMQ[0-9]+[EI]:.*" | head -1
}

#-------------------------------------------------------------------------------
# Pre-flight checks
#-------------------------------------------------------------------------------
log "=== Pre-flight Checks ==="
command -v runmqsc &>/dev/null || { echo "Error: runmqsc not found"; exit 1; }
log "runmqsc found: $(command -v runmqsc)"

# Verify DTCC BE QMgr is running
log "Checking DTCC BE QMgr: $DTCC_QMGR"
dspmq_out=$(dspmq -m "$DTCC_QMGR" 2>&1)
log "dspmq output: $dspmq_out"
echo "$dspmq_out" | grep -q "Running" || {
    echo "Error: DTCC BE QMgr '$DTCC_QMGR' is not available or not running"
    exit 1
}

#-------------------------------------------------------------------------------
# Step 1: Validate Client Alias (QREMOTE) configuration
#-------------------------------------------------------------------------------
log "=== Step 1: Validate Client Alias ==="
log "Executing: DISPLAY QREMOTE('$CLIENT_ALIAS') RQMNAME XMITQ"
qr_out=$(echo "DISPLAY QREMOTE('$CLIENT_ALIAS') RQMNAME XMITQ" | runmqsc "$DTCC_QMGR" 2>/dev/null)
log_cmd "$qr_out"

# Check if Client Alias exists
echo "$qr_out" | grep -qiE "AMQ8147I|not found" && {
    echo "Error: Client Alias '$CLIENT_ALIAS' not found on '$DTCC_QMGR'"
    exit 1
}

# Extract and validate RQMNAME and XMITQ
CLIENT_QMGR=$(mqsc_val "$qr_out" "RQMNAME")
XMITQ=$(mqsc_val "$qr_out" "XMITQ")
log "Extracted: CLIENT_QMGR=$CLIENT_QMGR, XMITQ=$XMITQ"

[[ -z "$XMITQ" || "$XMITQ" == " " ]] && { echo "Error: XMITQ is empty for '$CLIENT_ALIAS'"; exit 1; }
[[ -z "$CLIENT_QMGR" || "$CLIENT_QMGR" == " " ]] && { echo "Error: RQMNAME is empty for '$CLIENT_ALIAS'"; exit 1; }

#-------------------------------------------------------------------------------
# Step 2: Get XMITQ depth and Sender channel status
#-------------------------------------------------------------------------------
log "=== Step 2: XMITQ & Channel Status ==="

# Get current XMITQ depth
log "Executing: DISPLAY QSTATUS('$XMITQ') CURDEPTH"
qs_out=$(echo "DISPLAY QSTATUS('$XMITQ') CURDEPTH" | runmqsc "$DTCC_QMGR" 2>/dev/null)
log_cmd "$qs_out"
DEPTH_BEFORE=$(mqsc_val "$qs_out" "CURDEPTH")
DEPTH_BEFORE=${DEPTH_BEFORE:-0}
log "XMITQ Depth: $DEPTH_BEFORE"

# Find sender channel for this XMITQ (filter by CHLTYPE SDR)
log "Executing: DISPLAY CHANNEL(*) CHLTYPE(SDR) WHERE(XMITQ EQ '$XMITQ')"
chl_out=$(echo "DISPLAY CHANNEL(*) CHLTYPE(SDR) WHERE(XMITQ EQ '$XMITQ')" | runmqsc "$DTCC_QMGR" 2>/dev/null)
log_cmd "$chl_out"
SDR_CHL=$(echo "$chl_out" | grep "^   CHANNEL(" | sed 's/.*CHANNEL(\([^)]*\)).*/\1/' | head -1)
log "Sender Channel: ${SDR_CHL:-Not found}"

# Get channel status and perform ping based on state
SDR_STATUS="N/A" PING_RESULT=""
if [[ -n "$SDR_CHL" ]]; then
    log "Executing: DISPLAY CHSTATUS('$SDR_CHL')"
    chs_out=$(echo "DISPLAY CHSTATUS('$SDR_CHL')" | runmqsc "$DTCC_QMGR" 2>&1)
    log_cmd "$chs_out"

    if echo "$chs_out" | grep -qiE "AMQ8420I|not found"; then
        SDR_STATUS="INACTIVE"
        log "Channel is INACTIVE, performing ping test"
        PING_RESULT=$(do_ping)
    else
        # Extract STATUS value from CHSTATUS output
        SDR_STATUS=$(mqsc_val "$chs_out" "STATUS")
        SDR_STATUS=${SDR_STATUS:-Unknown}
        log "Channel Status: $SDR_STATUS"

        # Ping only for problematic states
        # RUNNING/BINDING/STARTING/INITIALIZING/STOPPING - channel is healthy or transitioning
        # STOPPED/RETRYING/PAUSED/INACTIVE - needs ping diagnostic
        case "$SDR_STATUS" in
            RUNNING|BINDING|STARTING|INITIALIZING|STOPPING)
                log "Channel in healthy/transitional state, skipping ping"
                ;;
            *)
                log "Non-running state ($SDR_STATUS), performing ping"
                PING_RESULT=$(do_ping)
                ;;
        esac
    fi
fi
[[ -n "$PING_RESULT" ]] && log "Ping Result: $PING_RESULT"

#-------------------------------------------------------------------------------
# Step 3: Send test message (if -s flag provided)
#-------------------------------------------------------------------------------
if [[ "$SEND_MSG" == "true" ]]; then
    log "=== Step 3: Send Test Message ==="

    # Locate amqsput binary
    amqsput=$(command -v amqsput 2>/dev/null)
    [[ -z "$amqsput" ]] && for p in /opt/mqm/samp/bin/amqsput /usr/mqm/samp/bin/amqsput; do
        [[ -x "$p" ]] && { amqsput="$p"; break; }
    done
    log "amqsput binary: ${amqsput:-Not found}"

    if [[ -z "$amqsput" ]]; then
        TEST_RESULT="FAILED" TEST_STATUS="amqsput not found"
    else
        # Build message: MQ_TEST_MSG|[CustomMsg|]Timestamp|Client Queue|Client QMgr|DTCC QMgr
        TS=$(date '+%Y-%m-%d %H:%M:%S')
        MSG_CONTENT="MQ_TEST_MSG|${CUSTOM_MSG:+$CUSTOM_MSG|}${TS}|Client Queue: ${CLIENT_QUEUE}|Client QMgr: ${CLIENT_QMGR}|DTCC QMgr: ${DTCC_QMGR}"
        MSG_SIZE=${#MSG_CONTENT}
        log "Message content: $MSG_CONTENT"
        log "Message size: $MSG_SIZE bytes"

        if [[ $MSG_SIZE -gt $MAX_MSG_SIZE ]]; then
            TEST_RESULT="FAILED" TEST_STATUS="Message too large ($MSG_SIZE > $MAX_MSG_SIZE bytes)"
        else
            log "Executing: amqsput $CLIENT_QUEUE $DTCC_QMGR $AMQSPUT_OPTS $CLIENT_ALIAS"
            if printf "%s\n\n" "$MSG_CONTENT" | "$amqsput" "$CLIENT_QUEUE" "$DTCC_QMGR" $AMQSPUT_OPTS "$CLIENT_ALIAS" >/dev/null 2>&1; then
                log "Message sent successfully, waiting 2s for processing"
                sleep 2

                # Check XMITQ status after send
                log "Checking XMITQ status after send"
                qs_after=$(echo "DISPLAY QSTATUS('$XMITQ') CURDEPTH LGETDATE LGETTIME" | runmqsc "$DTCC_QMGR" 2>/dev/null)
                log_cmd "$qs_after"
                DEPTH_AFTER=$(mqsc_val "$qs_after" "CURDEPTH")
                lgetd=$(mqsc_val "$qs_after" "LGETDATE") lgett=$(mqsc_val "$qs_after" "LGETTIME")
                [[ -n "$lgetd" && -n "$lgett" ]] && SEND_TIME="$lgetd $lgett"
                log "XMITQ Depth After: $DEPTH_AFTER, Last Get: $SEND_TIME"

                # Determine result based on XMITQ depth
                # SUCCESS = message left XMITQ (transmitted to remote)
                # FAILED = message stuck in XMITQ (channel not transmitting)
                if [[ "${DEPTH_AFTER:-0}" -le "$DEPTH_BEFORE" ]]; then
                    TEST_RESULT="SUCCESS"
                    TEST_STATUS="Transmitted (message left XMITQ)"
                else
                    TEST_RESULT="FAILED"
                    TEST_STATUS="Message stuck in XMITQ (check channel status)"
                fi
                log "Test Result: $TEST_RESULT, Status: $TEST_STATUS"
            else
                TEST_RESULT="FAILED" TEST_STATUS="amqsput failed"
                log "amqsput command failed"
            fi
        fi
    fi
fi

#-------------------------------------------------------------------------------
# Display Summary
#-------------------------------------------------------------------------------
log "=== Displaying Summary ==="
echo ""
echo "===================================================================================="
echo "                           EDGE CONNECTION SUMMARY                                  "
echo "===================================================================================="
printf "  %-20s : %s\n" "DTCC BE QMgr" "$DTCC_QMGR"
printf "  %-20s : %s\n" "Client Queue" "$CLIENT_QUEUE"
printf "  %-20s : %s\n" "Client Alias" "$CLIENT_ALIAS"
printf "  %-20s : %s\n" "Client QMgr" "$CLIENT_QMGR"
echo "------------------------------------------------------------------------------------"
echo "  [BEFORE] Connectivity Status"
echo "------------------------------------------------------------------------------------"
printf "  %-20s : %s\n" "XMITQ" "$XMITQ"
printf "  %-20s : %s\n" "XMITQ Depth" "$DEPTH_BEFORE"
printf "  %-20s : %s\n" "Sender Channel" "${SDR_CHL:-Not found}"
printf "  %-20s : %s\n" "Channel Status" "$SDR_STATUS"
[[ -n "$PING_RESULT" ]] && printf "  %-20s : %s\n" "Ping Result" "$PING_RESULT"

if [[ "$SEND_MSG" == "true" ]]; then
    echo "------------------------------------------------------------------------------------"
    echo "  [AFTER] Message Delivery Proof"
    echo "------------------------------------------------------------------------------------"
    printf "  %-20s : %s\n" "Result" "$TEST_RESULT"
    printf "  %-20s : %s\n" "Status" "$TEST_STATUS"
    printf "  %-20s : %s bytes\n" "Message Size" "$MSG_SIZE"
    [[ -n "$SEND_TIME" ]] && printf "  %-20s : %s\n" "Send Time" "$SEND_TIME"
    printf "  %-20s : %s\n" "XMITQ Depth" "${DEPTH_AFTER:-N/A}"
    printf "  %-20s : %s\n" "Message" "$MSG_CONTENT"
fi

echo "===================================================================================="
echo ""

[[ "$SEND_MSG" == "true" && "$TEST_RESULT" == "FAILED" ]] && exit 1
exit 0
