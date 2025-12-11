#!/bin/bash
#==============================================================================
# MQ Pre-flight Route Validator - Dynamic Route Discovery
#
# Automatically discovers and validates the complete message route by
# following queue definitions like an MQ Architect would.
#
# Usage: ./mq_preflight_validator.sh --qmgr <QMGR> --queue <QUEUE>
#
# The script will:
#   1. Connect to the starting QMgr
#   2. Check the queue definition
#   3. If QREMOTE → follow to next QMgr (from RQMNAME or XMITQ)
#   4. Repeat until QLOCAL found or QMgr not in config (external boundary)
#   5. Validate all objects at each hop
#==============================================================================

set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/mq_config.yaml"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Counters
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
WARNING_CHECKS=0

# Output mode (default: summary only)
QUIET_MODE=true

# Route tracking
declare -a ROUTE_QMGRS=()
declare -a ROUTE_QUEUES=()
declare -a ROUTE_QTYPES=()
declare -a ROUTE_CHANNELS=()
declare -a ROUTE_XMITQS=()
declare -a ROUTE_XMITQ_DEPTHS=()
declare -a ROUTE_CHANNEL_STATUS=()
declare -a ROUTE_QUEUE_INFO=()
declare -a ROUTE_CHANNEL_INFO=()
declare -a ROUTE_ISSUES=()
ROUTE_INCOMPLETE=""
ROUTE_INCOMPLETE_REASON=""

#==============================================================================
# Output Functions
#==============================================================================

print_header() {
    $QUIET_MODE && return
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════════════${NC}"
}

print_subheader() {
    $QUIET_MODE && return
    echo ""
    echo -e "${CYAN}┌─────────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│  $1${NC}"
    echo -e "${CYAN}└─────────────────────────────────────────────────────────────────────┘${NC}"
}

print_check() {
    ((TOTAL_CHECKS++))
    $QUIET_MODE && return
    echo -ne "  ├─ $1: "
}

print_pass() {
    ((PASSED_CHECKS++))
    $QUIET_MODE && return
    echo -e "${GREEN}✓ $1${NC}"
}

print_fail() {
    ((FAILED_CHECKS++))
    $QUIET_MODE && return
    echo -e "${RED}✗ $1${NC}"
}

print_warn() {
    ((WARNING_CHECKS++))
    $QUIET_MODE && return
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    $QUIET_MODE && return
    echo -e "  │    ${CYAN}↳ $1${NC}"
}

print_route_arrow() {
    echo -e "  │"
    echo -e "  │    ${YELLOW}▼ Next Hop${NC}"
    echo -e "  │"
}

#==============================================================================
# YAML Parser
#==============================================================================

get_qmgr_config() {
    local config_file=$1
    local qmgr=$2
    local key=$3
    local default=$4
    
    [[ ! -f "$config_file" ]] && echo "$default" && return
    
    local result=$(awk -v qm="$qmgr:" -v k="$key:" '
        $0 ~ qm {found=1; next}
        found && /^  [a-zA-Z]/ && !/^    / {found=0}
        found && /^[^ ]/ {found=0}
        found && $0 ~ k {
            sub(/^[[:space:]]+/, "")
            sub(/^[^:]+:[[:space:]]*/, "")
            sub(/[[:space:]]*#.*$/, "")
            gsub(/"/, ""); gsub(/'\''/, "")
            gsub(/^[[:space:]]+|[[:space:]]+$/, "")
            print; exit
        }
    ' "$config_file")
    
    echo "${result:-$default}"
}

# Check if QMgr exists in config
qmgr_in_config() {
    local qmgr=$1
    local host=$(get_qmgr_config "$CONFIG_FILE" "$qmgr" "host" "")
    [[ -n "$host" ]]
}

#==============================================================================
# MQ Connection Helper
#==============================================================================

run_mqsc() {
    local qmgr=$1
    local command=$2
    
    local host=$(get_qmgr_config "$CONFIG_FILE" "$qmgr" "host" "")
    local port=$(get_qmgr_config "$CONFIG_FILE" "$qmgr" "port" "1414")
    local channel=$(get_qmgr_config "$CONFIG_FILE" "$qmgr" "channel" "SYSTEM.DEF.SVRCONN")
    local ssl_cipher=$(get_qmgr_config "$CONFIG_FILE" "$qmgr" "ssl_cipher_spec" "")
    local ssl_keyr=$(get_qmgr_config "$CONFIG_FILE" "$qmgr" "ssl_key_repository" "")
    
    if [[ -z "$host" ]]; then
        echo "ERROR: QMgr $qmgr not found in config"
        return 1
    fi
    
    local ccdt_dir="/tmp/mq_preflight_$$_${qmgr//\./_}"
    mkdir -p "$ccdt_dir"
    
    local ssl_block=""
    if [[ -n "$ssl_cipher" ]]; then
        ssl_block='"transmissionSecurity": {"cipherSpecification": "'"$ssl_cipher"'"},'
        export MQSSLKEYR="$ssl_keyr"
    fi
    
    cat > "$ccdt_dir/ccdt.json" << JSONEOF
{
  "channel": [{
    "name": "$channel",
    "clientConnection": {
      "connection": [{"host": "$host", "port": $port}],
      "queueManager": "$qmgr"
    },
    $ssl_block
    "type": "clientConnection"
  }]
}
JSONEOF
    
    export MQCCDTURL="file://$ccdt_dir/ccdt.json"
    unset MQCHLLIB MQCHLTAB MQSERVER
    
    local result
    result=$(echo "$command" | /opt/mqm/bin/runmqsc -c "$qmgr" 2>&1)
    local rc=$?
    
    rm -rf "$ccdt_dir"
    
    echo "$result"
    return $rc
}

#==============================================================================
# Queue Analysis Functions
#==============================================================================

# Analyze a queue and return its type and next hop info
# Sets global variables for all queue types
# Q_TYPE: QLOCAL, QREMOTE, QALIAS, QMODEL, QCLUSTER
analyze_queue() {
    local qmgr=$1
    local queue=$2
    
    # Reset all global variables
    Q_TYPE=""
    Q_RNAME=""
    Q_RQMNAME=""
    Q_XMITQ=""
    Q_TARGTYPE=""
    Q_TARGET=""
    Q_CLUSTER=""
    Q_CLUSNL=""
    Q_DEFBIND=""
    Q_CLWLPRTY=""
    Q_CLWLRANK=""
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY QUEUE($queue) TYPE TARGTYPE RNAME RQMNAME XMITQ TARGET CLUSTER CLUSNL DEFBIND CLWLPRTY CLWLRANK")
    
    if echo "$result" | grep -q "AMQ8147E"; then
        return 1  # Queue not found
    fi
    
    Q_TYPE=$(echo "$result" | grep -oP "TYPE\(\K[^)]+" | head -1)
    Q_TARGTYPE=$(echo "$result" | grep -oP "TARGTYPE\(\K[^)]+" | head -1)
    Q_RNAME=$(echo "$result" | grep -oP "RNAME\(\K[^)]+" | head -1 | xargs)
    Q_RQMNAME=$(echo "$result" | grep -oP "RQMNAME\(\K[^)]+" | head -1 | xargs)
    Q_XMITQ=$(echo "$result" | grep -oP "XMITQ\(\K[^)]+" | head -1 | xargs)
    Q_TARGET=$(echo "$result" | grep -oP "TARGET\(\K[^)]+" | head -1 | xargs)
    Q_CLUSTER=$(echo "$result" | grep -oP "CLUSTER\(\K[^)]+" | head -1 | xargs)
    Q_CLUSNL=$(echo "$result" | grep -oP "CLUSNL\(\K[^)]+" | head -1 | xargs)
    Q_DEFBIND=$(echo "$result" | grep -oP "DEFBIND\(\K[^)]+" | head -1)
    Q_CLWLPRTY=$(echo "$result" | grep -oP "CLWLPRTY\(\K[0-9]+" | head -1)
    Q_CLWLRANK=$(echo "$result" | grep -oP "CLWLRANK\(\K[0-9]+" | head -1)
    
    return 0
}

# Get detailed queue info based on type
get_queue_details() {
    local qmgr=$1
    local queue=$2
    local qtype=$3
    
    local result details=""
    
    case "$qtype" in
        QLOCAL)
            result=$(run_mqsc "$qmgr" "DISPLAY QLOCAL($queue) CURDEPTH MAXDEPTH GET PUT MAXMSGL DEFPSIST TRIGTYPE TRIGGER CLUSTER")
            local depth=$(echo "$result" | grep -oP "CURDEPTH\(\K[0-9]+" | head -1)
            local maxd=$(echo "$result" | grep -oP "MAXDEPTH\(\K[0-9]+" | head -1)
            local get=$(echo "$result" | grep -oP "GET\(\K[A-Z]+" | head -1)
            local put=$(echo "$result" | grep -oP "PUT\(\K[A-Z]+" | head -1)
            local cluster=$(echo "$result" | grep -oP "CLUSTER\(\K[^)]+" | head -1 | xargs)
            details="Depth:${depth:-0}/${maxd:-5000} GET:${get:-?} PUT:${put:-?}"
            [[ -n "$cluster" && "$cluster" != " " ]] && details="$details [Cluster:$cluster]"
            ;;
        QREMOTE)
            details="→ ${Q_RQMNAME:-?} (${Q_RNAME:-?})"
            [[ -n "$Q_XMITQ" && "$Q_XMITQ" != " " ]] && details="$details XMITQ:$Q_XMITQ"
            ;;
        QALIAS)
            local target="${Q_TARGET:-$Q_RNAME}"
            details="→ $target (${Q_TARGTYPE:-QUEUE})"
            ;;
        QMODEL)
            result=$(run_mqsc "$qmgr" "DISPLAY QMODEL($queue) DEFTYPE MAXDEPTH")
            local deftype=$(echo "$result" | grep -oP "DEFTYPE\(\K[^)]+" | head -1)
            details="Template (${deftype:-TEMPDYN})"
            ;;
        QCLUSTER)
            details="Cluster:${Q_CLUSTER:-?} Bind:${Q_DEFBIND:-?}"
            [[ -n "$Q_CLWLPRTY" ]] && details="$details Pri:$Q_CLWLPRTY"
            ;;
    esac
    
    echo "$details"
}

# Get channel serving an XMITQ
get_channel_for_xmitq() {
    local qmgr=$1
    local xmitq=$2
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY CHANNEL(*) CHLTYPE XMITQ WHERE(XMITQ EQ $xmitq)")
    
    echo "$result" | grep "CHANNEL(" | grep -v "SYSTEM" | grep -v "DISPLAY" | head -1 | grep -oP "CHANNEL\(\K[^)]+"
}

# Get channel type and details
get_channel_details() {
    local qmgr=$1
    local channel=$2
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY CHANNEL($channel) CHLTYPE CONNAME XMITQ MAXMSGL TRPTYPE SSLCIPH CLUSTER")
    
    local chltype=$(echo "$result" | grep -oP "CHLTYPE\(\K[^)]+" | head -1)
    local conname=$(echo "$result" | grep -oP "CONNAME\(\K[^)]+" | head -1)
    local trptype=$(echo "$result" | grep -oP "TRPTYPE\(\K[^)]+" | head -1)
    local sslciph=$(echo "$result" | grep -oP "SSLCIPH\(\K[^)]+" | head -1 | xargs)
    local cluster=$(echo "$result" | grep -oP "CLUSTER\(\K[^)]+" | head -1 | xargs)
    
    # Map channel type to readable name
    local chl_type_name=""
    case "$chltype" in
        SDR)      chl_type_name="Sender" ;;
        RCVR)     chl_type_name="Receiver" ;;
        SVR)      chl_type_name="Server" ;;
        RQSTR)    chl_type_name="Requester" ;;
        CLNTCONN) chl_type_name="Client Conn" ;;
        SVRCONN)  chl_type_name="Server Conn" ;;
        CLUSSDR)  chl_type_name="Cluster Sdr" ;;
        CLUSRCVR) chl_type_name="Cluster Rcv" ;;
        *)        chl_type_name="$chltype" ;;
    esac
    
    local details="$chl_type_name"
    [[ -n "$conname" ]] && details="$details → $conname"
    [[ -n "$sslciph" && "$sslciph" != " " ]] && details="$details [SSL]"
    [[ -n "$cluster" && "$cluster" != " " ]] && details="$details [Cluster:$cluster]"
    
    echo "$chltype:$details"
}

# Check channel status with details
check_channel_status() {
    local qmgr=$1
    local channel=$2
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY CHSTATUS($channel) STATUS SUBSTATE CONNAME MSGS BYTSSENT BYTSRCVD")
    
    if echo "$result" | grep -q "STATUS(RUNNING)"; then
        local msgs=$(echo "$result" | grep -oP "MSGS\(\K[0-9]+" | head -1)
        echo "RUNNING:${msgs:-0} msgs"
    elif echo "$result" | grep -q "STATUS(RETRYING)"; then
        echo "RETRYING"
    elif echo "$result" | grep -q "STATUS(STOPPED)"; then
        echo "STOPPED"
    elif echo "$result" | grep -q "STATUS(BINDING)"; then
        echo "BINDING"
    elif echo "$result" | grep -q "STATUS(STARTING)"; then
        echo "STARTING"
    elif echo "$result" | grep -q "STATUS(PAUSED)"; then
        echo "PAUSED"
    elif echo "$result" | grep -q "AMQ8420E"; then
        # Channel not active - check if definition exists and ping test
        local def_check=$(run_mqsc "$qmgr" "DISPLAY CHANNEL($channel) CHLTYPE CONNAME")
        if echo "$def_check" | grep -q "CHANNEL("; then
            # Do ping test to verify connectivity
            local ping_result=$(run_mqsc "$qmgr" "PING CHANNEL($channel)")
            if echo "$ping_result" | grep -q "AMQ8020I"; then
                echo "INACTIVE_OK:Ping successful"
            else
                echo "INACTIVE_FAIL:Ping failed"
            fi
        else
            echo "NOT_DEFINED"
        fi
    else
        # Check if channel definition exists
        local def_check=$(run_mqsc "$qmgr" "DISPLAY CHANNEL($channel) CHLTYPE")
        if echo "$def_check" | grep -q "CHANNEL("; then
            local ping_result=$(run_mqsc "$qmgr" "PING CHANNEL($channel)")
            if echo "$ping_result" | grep -q "AMQ8020I"; then
                echo "INACTIVE_OK:Ping successful"
            else
                echo "INACTIVE_FAIL:Ping failed"
            fi
        else
            echo "NOT_DEFINED"
        fi
    fi
}

# Find receiver channel for a sender channel (on remote QMgr)
find_receiver_channel() {
    local qmgr=$1
    local sender_channel=$2
    
    # Common naming patterns for receiver channels
    # Pattern 1: Same name as sender
    # Pattern 2: Replace .TO. with .FROM. or vice versa
    # Pattern 3: Reverse the direction in name
    
    local result
    # Try exact name first
    result=$(run_mqsc "$qmgr" "DISPLAY CHANNEL($sender_channel) CHLTYPE" 2>/dev/null)
    if echo "$result" | grep -q "CHLTYPE(RCVR)"; then
        echo "$sender_channel"
        return 0
    fi
    
    # Try to find any RCVR channel
    result=$(run_mqsc "$qmgr" "DISPLAY CHANNEL(*) CHLTYPE WHERE(CHLTYPE EQ RCVR)" 2>/dev/null)
    local rcvr_channels=$(echo "$result" | grep -oP "CHANNEL\(\K[^)]+" | grep -v "SYSTEM")
    
    for rcvr in $rcvr_channels; do
        # Check if names are related
        if [[ "$rcvr" == "$sender_channel" ]]; then
            echo "$rcvr"
            return 0
        fi
    done
    
    echo ""
    return 1
}

# Check receiver channel status on remote QMgr
check_receiver_status() {
    local qmgr=$1
    local rcvr_channel=$2
    
    if [[ -z "$rcvr_channel" ]]; then
        echo "NOT_FOUND"
        return
    fi
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY CHSTATUS($rcvr_channel) STATUS MSGS" 2>/dev/null)
    
    if echo "$result" | grep -q "STATUS(RUNNING)"; then
        local msgs=$(echo "$result" | grep -oP "MSGS\(\K[0-9]+" | head -1)
        echo "RUNNING:${msgs:-0}"
    elif echo "$result" | grep -q "AMQ8420E"; then
        echo "INACTIVE"
    else
        local status=$(echo "$result" | grep -oP "STATUS\(\K[^)]+" | head -1)
        echo "${status:-UNKNOWN}"
    fi
}

# Check listener status
check_listener_status() {
    local qmgr=$1
    local port=$2
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY LSSTATUS(*) PORT")
    
    if echo "$result" | grep -q "PORT($port)"; then
        echo "RUNNING"
    else
        echo "NOT FOUND"
    fi
}

# Check XMITQ health
check_xmitq_health() {
    local qmgr=$1
    local xmitq=$2
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY QLOCAL($xmitq) CURDEPTH MAXDEPTH IPPROCS GET PUT TRIGGER TRIGTYPE")
    
    local curdepth=$(echo "$result" | grep -oP "CURDEPTH\(\K[0-9]+" | head -1)
    local maxdepth=$(echo "$result" | grep -oP "MAXDEPTH\(\K[0-9]+" | head -1)
    local ipprocs=$(echo "$result" | grep -oP "IPPROCS\(\K[0-9]+" | head -1)
    local get_status=$(echo "$result" | grep -oP "GET\(\K[A-Z]+" | head -1)
    local put_status=$(echo "$result" | grep -oP "PUT\(\K[A-Z]+" | head -1)
    
    echo "${curdepth:-0}:${maxdepth:-5000}:${ipprocs:-0}:${get_status:-ENABLED}:${put_status:-ENABLED}"
}

# Check QLOCAL health (for destination queue)
check_qlocal_health() {
    local qmgr=$1
    local queue=$2
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY QLOCAL($queue) CURDEPTH MAXDEPTH GET PUT MAXMSGL")
    
    local curdepth=$(echo "$result" | grep -oP "CURDEPTH\(\K[0-9]+" | head -1)
    local maxdepth=$(echo "$result" | grep -oP "MAXDEPTH\(\K[0-9]+" | head -1)
    local get_status=$(echo "$result" | grep -oP "GET\(\K[A-Z]+" | head -1)
    local put_status=$(echo "$result" | grep -oP "PUT\(\K[A-Z]+" | head -1)
    local maxmsgl=$(echo "$result" | grep -oP "MAXMSGL\(\K[0-9]+" | head -1)
    
    echo "${curdepth:-0}:${maxdepth:-5000}:${get_status:-ENABLED}:${put_status:-ENABLED}:${maxmsgl:-4194304}"
}

# Check QMgr health
check_qmgr_health() {
    local qmgr=$1
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY QMGR DEADQ CHLAUTH CONNAUTH CHINIT")
    
    local deadq=$(echo "$result" | grep -oP "DEADQ\(\K[^)]+" | head -1 | xargs)
    local chinit=$(echo "$result" | grep -oP "CHINIT\(\K[^)]+" | head -1)
    
    echo "${deadq:-NONE}:${chinit:-UNKNOWN}"
}

# Check channel definition details
check_channel_definition() {
    local qmgr=$1
    local channel=$2
    
    local result
    result=$(run_mqsc "$qmgr" "DISPLAY CHANNEL($channel) CONNAME XMITQ MAXMSGL HBINT")
    
    local conname=$(echo "$result" | grep -oP "CONNAME\(\K[^)]+" | head -1)
    local maxmsgl=$(echo "$result" | grep -oP "MAXMSGL\(\K[0-9]+" | head -1)
    
    echo "${conname:-UNKNOWN}:${maxmsgl:-4194304}"
}

#==============================================================================
# Route Discovery
#==============================================================================

discover_route() {
    local start_qmgr=$1
    local start_queue=$2
    
    local current_qmgr="$start_qmgr"
    local current_queue="$start_queue"
    local hop=0
    local max_hops=10  # Prevent infinite loops
    
    if ! $QUIET_MODE; then
        print_header "Route Discovery"
        echo ""
        echo -e "  ${CYAN}Starting Point:${NC} $start_qmgr / $start_queue"
        echo -e "  ${CYAN}Discovering route by following queue definitions...${NC}"
    fi
    
    while [[ $hop -lt $max_hops ]]; do
        ((hop++))
        
        # Check if QMgr is in our config
        if ! qmgr_in_config "$current_qmgr"; then
            $QUIET_MODE || echo -e "  ${YELLOW}► Reached external boundary: $current_qmgr (not in config)${NC}"
            break
        fi
        
        # Add to route
        ROUTE_QMGRS+=("$current_qmgr")
        ROUTE_QUEUES+=("$current_queue")
        
        $QUIET_MODE || echo -e "\n  ${GREEN}► HOP $hop: $current_qmgr${NC}"
        
        # Analyze queue
        if ! analyze_queue "$current_qmgr" "$current_queue"; then
            $QUIET_MODE || echo -e "    ${RED}Queue '$current_queue' not found!${NC}"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            break
        fi
        
        $QUIET_MODE || echo -e "    Queue: $current_queue"
        $QUIET_MODE || echo -e "    Type: $Q_TYPE"
        
        # Handle each queue type
        case "$Q_TYPE" in
            QLOCAL)
                # Check if it's a cluster queue
                if [[ -n "$Q_CLUSTER" && "$Q_CLUSTER" != " " ]]; then
                    $QUIET_MODE || echo -e "    ${GREEN}✓ Cluster Queue (QLOCAL) - Cluster: $Q_CLUSTER${NC}"
                    ROUTE_QTYPES+=("QLOCAL[Cluster]")
                else
                    $QUIET_MODE || echo -e "    ${GREEN}✓ Final destination (QLOCAL)${NC}"
                    ROUTE_QTYPES+=("QLOCAL")
                fi
                ROUTE_XMITQS+=("")
                ROUTE_CHANNELS+=("")
                break
                ;;
                
            QREMOTE)
                $QUIET_MODE || echo -e "    Remote QMgr: $Q_RQMNAME"
                $QUIET_MODE || echo -e "    Remote Queue: $Q_RNAME"
                ROUTE_QTYPES+=("QREMOTE")
                
                # Determine XMITQ
                local xmitq="$Q_XMITQ"
                if [[ -z "$xmitq" || "$xmitq" == " " ]]; then
                    xmitq="$Q_RQMNAME"
                fi
                $QUIET_MODE || echo -e "    XMITQ: $xmitq"
                ROUTE_XMITQS+=("$xmitq")
                
                # Find channel
                local channel=$(get_channel_for_xmitq "$current_qmgr" "$xmitq")
                if [[ -n "$channel" ]]; then
                    $QUIET_MODE || echo -e "    Channel: $channel"
                    ROUTE_CHANNELS+=("$channel")
                else
                    $QUIET_MODE || echo -e "    ${YELLOW}Channel: (not found for XMITQ)${NC}"
                    ROUTE_CHANNELS+=("")
                fi
                
                # Multi-hop routing logic
                local next_qmgr=""
                local next_queue=""
                
                # Check if XMITQ points to an intermediate QMgr (multi-hop)
                if [[ "$xmitq" != "$Q_RQMNAME" ]] && qmgr_in_config "$xmitq"; then
                    $QUIET_MODE || echo -e "    ${CYAN}► Multi-hop: via $xmitq to final destination $Q_RQMNAME${NC}"
                    next_qmgr="$xmitq"
                    next_queue="__CHECK_XMITQ_TO_${Q_RQMNAME}__"
                elif qmgr_in_config "$Q_RQMNAME"; then
                    next_qmgr="$Q_RQMNAME"
                    next_queue="$Q_RNAME"
                elif [[ -n "$xmitq" ]] && qmgr_in_config "$xmitq"; then
                    next_qmgr="$xmitq"
                    next_queue="${Q_RNAME:-$current_queue}"
                else
                    $QUIET_MODE || echo -e "    ${YELLOW}► Final destination '$Q_RQMNAME' not in config (external boundary)${NC}"
                    break
                fi
                
                # If next_queue is our special marker, check XMITQ chain on intermediate
                if [[ "$next_queue" == __CHECK_XMITQ_TO_* ]]; then
                    local final_dest=$(echo "$next_queue" | sed 's/__CHECK_XMITQ_TO_//' | sed 's/__$//')
                    current_qmgr="$next_qmgr"
                    
                    # On intermediate QMgr, check for XMITQ to final destination
                    $QUIET_MODE || echo ""
                    $QUIET_MODE || echo -e "  ${GREEN}► HOP $((hop+1)): $current_qmgr (Intermediate Gateway)${NC}"
                    
                    ROUTE_QMGRS+=("$current_qmgr")
                    ROUTE_QUEUES+=("(pass-through)")
                    ROUTE_QTYPES+=("GATEWAY")
                    
                    # Look for XMITQ to final destination
                    local final_xmitq=""
                    local xmitq_check=$(run_mqsc "$current_qmgr" "DISPLAY QLOCAL($final_dest) USAGE" 2>/dev/null)
                    if echo "$xmitq_check" | grep -q "USAGE(XMITQ)"; then
                        final_xmitq="$final_dest"
                    else
                        for pattern in "$final_dest" "${final_dest}.XMITQ" "TO.${final_dest}"; do
                            xmitq_check=$(run_mqsc "$current_qmgr" "DISPLAY QLOCAL($pattern) USAGE" 2>/dev/null)
                            if echo "$xmitq_check" | grep -q "USAGE(XMITQ)"; then
                                final_xmitq="$pattern"
                                break
                            fi
                        done
                    fi
                    
                    if [[ -n "$final_xmitq" ]]; then
                        $QUIET_MODE || echo -e "    XMITQ to $final_dest: $final_xmitq"
                        ROUTE_XMITQS+=("$final_xmitq")
                        
                        local final_channel=$(get_channel_for_xmitq "$current_qmgr" "$final_xmitq")
                        if [[ -n "$final_channel" ]]; then
                            $QUIET_MODE || echo -e "    Channel: $final_channel"
                            ROUTE_CHANNELS+=("$final_channel")
                        else
                            ROUTE_CHANNELS+=("")
                            ROUTE_ISSUES+=("CHANNEL|$current_qmgr|No sender channel found for XMITQ '$final_xmitq'")
                        fi
                        
                        if qmgr_in_config "$final_dest"; then
                            current_qmgr="$final_dest"
                            current_queue="$Q_RNAME"
                        else
                            $QUIET_MODE || echo -e "    ${YELLOW}► Final destination '$final_dest' not in config (external boundary)${NC}"
                            ROUTE_INCOMPLETE="$final_dest"
                            ROUTE_INCOMPLETE_REASON="NOT_IN_CONFIG"
                            break
                        fi
                    else
                        # Check if XMITQ really doesn't exist OR if destination QMgr is not in config
                        if ! qmgr_in_config "$final_dest"; then
                            $QUIET_MODE || echo -e "    ${YELLOW}► '$final_dest' not in mq_config.yaml${NC}"
                            ROUTE_XMITQS+=("")
                            ROUTE_CHANNELS+=("")
                            ROUTE_INCOMPLETE="$final_dest"
                            ROUTE_INCOMPLETE_REASON="NOT_IN_CONFIG"
                            ROUTE_ISSUES+=("CONFIG|$final_dest|QMgr not in mq_config.yaml - add connection details to trace further")
                        else
                            $QUIET_MODE || echo -e "    ${YELLOW}No XMITQ found for $final_dest on $current_qmgr${NC}"
                            ROUTE_XMITQS+=("")
                            ROUTE_CHANNELS+=("")
                            ROUTE_INCOMPLETE="$final_dest"
                            ROUTE_INCOMPLETE_REASON="NO_XMITQ"
                            ROUTE_ISSUES+=("ROUTING|$current_qmgr|No XMITQ for '$final_dest' - check routing definitions")
                        fi
                        break
                    fi
                    
                    ((hop++))
                else
                    current_qmgr="$next_qmgr"
                    current_queue="$next_queue"
                fi
                ;;
                
            QALIAS)
                local target="${Q_TARGET:-$Q_RNAME}"
                $QUIET_MODE || echo -e "    Target Type: ${Q_TARGTYPE:-QUEUE}"
                $QUIET_MODE || echo -e "    Target: $target"
                ROUTE_QTYPES+=("QALIAS")
                ROUTE_XMITQS+=("")
                ROUTE_CHANNELS+=("")
                
                if [[ "${Q_TARGTYPE:-QUEUE}" == "QUEUE" ]]; then
                    current_queue="$target"
                    $QUIET_MODE || echo -e "    ${CYAN}(Following alias to: $target)${NC}"
                elif [[ "${Q_TARGTYPE}" == "TOPIC" ]]; then
                    $QUIET_MODE || echo -e "    ${GREEN}✓ Alias points to TOPIC: $target${NC}"
                    break
                fi
                ;;
                
            QMODEL)
                $QUIET_MODE || echo -e "    ${YELLOW}Model Queue (template for dynamic queues)${NC}"
                ROUTE_QTYPES+=("QMODEL")
                ROUTE_XMITQS+=("")
                ROUTE_CHANNELS+=("")
                break
                ;;
                
            QCLUSTER)
                $QUIET_MODE || echo -e "    Cluster: ${Q_CLUSTER:-$Q_CLUSNL}"
                $QUIET_MODE || echo -e "    Binding: ${Q_DEFBIND:-OPEN}"
                $QUIET_MODE || { [[ -n "$Q_CLWLPRTY" ]] && echo -e "    Workload Priority: $Q_CLWLPRTY"; }
                $QUIET_MODE || { [[ -n "$Q_CLWLRANK" ]] && echo -e "    Workload Rank: $Q_CLWLRANK"; }
                $QUIET_MODE || echo -e "    ${GREEN}✓ Cluster Queue (workload balanced)${NC}"
                ROUTE_QTYPES+=("QCLUSTER")
                ROUTE_XMITQS+=("")
                ROUTE_CHANNELS+=("")
                break
                ;;
                
            *)
                echo -e "    ${YELLOW}Unknown queue type: $Q_TYPE${NC}"
                ROUTE_QTYPES+=("$Q_TYPE")
                ROUTE_XMITQS+=("")
                ROUTE_CHANNELS+=("")
                break
                ;;
        esac
    done
    
    if [[ $hop -ge $max_hops ]]; then
        $QUIET_MODE || echo -e "\n  ${RED}► Max hops ($max_hops) reached - possible loop!${NC}"
    fi
    
    # Print discovered route (only in verbose mode)
    if ! $QUIET_MODE; then
        echo ""
        print_header "Discovered Route"
        echo ""
        printf "  "
        for i in "${!ROUTE_QMGRS[@]}"; do
            printf "%s" "${ROUTE_QMGRS[$i]}"
            if [[ $i -lt $((${#ROUTE_QMGRS[@]} - 1)) ]]; then
                printf " → "
            fi
        done
        if [[ -n "$Q_RQMNAME" ]] && ! qmgr_in_config "$Q_RQMNAME"; then
            printf " → ${Q_RQMNAME} (external)"
        fi
        echo ""
    fi
}

#==============================================================================
# Validation
#==============================================================================

validate_route() {
    print_header "Route Validation"
    
    for i in "${!ROUTE_QMGRS[@]}"; do
        local qmgr="${ROUTE_QMGRS[$i]}"
        local queue="${ROUTE_QUEUES[$i]}"
        local xmitq="${ROUTE_XMITQS[$i]}"
        local channel="${ROUTE_CHANNELS[$i]}"
        
        local hop_type="Gateway"
        [[ $i -eq 0 ]] && hop_type="Origin"
        [[ $i -eq $((${#ROUTE_QMGRS[@]} - 1)) ]] && [[ -z "$xmitq" ]] && hop_type="Destination"
        
        print_subheader "HOP $((i+1)): $qmgr ($hop_type)"
        
        # Check connection
        print_check "Connection"
        local ping_result=$(run_mqsc "$qmgr" "PING QMGR")
        if echo "$ping_result" | grep -q "AMQ8415I"; then
            print_pass "Connected"
        else
            print_fail "Cannot connect"
            continue
        fi
        
        # Check QMgr health (first hop only)
        if [[ $i -eq 0 ]]; then
            print_check "QMgr Health"
            local qmgr_health=$(check_qmgr_health "$qmgr")
            local deadq=$(echo "$qmgr_health" | cut -d: -f1)
            if [[ -n "$deadq" && "$deadq" != "NONE" && "$deadq" != " " ]]; then
                print_pass "DLQ: $deadq"
            else
                print_warn "No Dead Letter Queue defined"
            fi
        fi
        
        # Check queue
        print_check "Queue '$queue'"
        if analyze_queue "$qmgr" "$queue"; then
            if [[ "$Q_TYPE" == "QLOCAL" ]]; then
                print_pass "QLOCAL (destination)"
                # Additional checks for destination queue
                local qlocal_health=$(check_qlocal_health "$qmgr" "$queue")
                local qdepth=$(echo "$qlocal_health" | cut -d: -f1)
                local qmaxdepth=$(echo "$qlocal_health" | cut -d: -f2)
                local qget=$(echo "$qlocal_health" | cut -d: -f3)
                local qput=$(echo "$qlocal_health" | cut -d: -f4)
                
                print_check "Queue PUT enabled"
                if [[ "$qput" == "ENABLED" ]]; then
                    print_pass "Yes"
                else
                    print_fail "PUT DISABLED!"
                fi
                
                print_check "Queue depth"
                if [[ "$qmaxdepth" -gt 0 ]]; then
                    local qpct=$((qdepth * 100 / qmaxdepth))
                    if [[ $qpct -gt 90 ]]; then
                        print_fail "$qdepth/$qmaxdepth (${qpct}% FULL!)"
                    elif [[ $qpct -gt 70 ]]; then
                        print_warn "$qdepth/$qmaxdepth (${qpct}%)"
                    else
                        print_pass "$qdepth/$qmaxdepth"
                    fi
                else
                    print_pass "Depth: $qdepth"
                fi
                
            elif [[ "$Q_TYPE" == "QREMOTE" ]]; then
                print_pass "QREMOTE → $Q_RQMNAME"
                print_info "Target: $Q_RNAME"
            else
                print_pass "$Q_TYPE"
            fi
        else
            print_fail "NOT FOUND"
            continue
        fi
        
        # If XMITQ exists, validate it
        if [[ -n "$xmitq" ]]; then
            print_check "XMITQ '$xmitq'"
            local health=$(check_xmitq_health "$qmgr" "$xmitq")
            local depth=$(echo "$health" | cut -d: -f1)
            local maxdepth=$(echo "$health" | cut -d: -f2)
            local ipprocs=$(echo "$health" | cut -d: -f3)
            local xmit_get=$(echo "$health" | cut -d: -f4)
            local xmit_put=$(echo "$health" | cut -d: -f5)
            
            # Store for summary
            ROUTE_XMITQ_DEPTHS[$i]="Depth:$depth/$maxdepth"
            
            if [[ "$maxdepth" -gt 0 ]]; then
                local pct=$((depth * 100 / maxdepth))
                if [[ $pct -gt 80 ]]; then
                    print_fail "Depth $depth/$maxdepth (${pct}% FULL!)"
                elif [[ $pct -gt 50 ]]; then
                    print_warn "Depth $depth/$maxdepth (${pct}%)"
                else
                    print_pass "Depth $depth/$maxdepth"
                fi
            else
                print_pass "Depth $depth"
            fi
            
            # Check XMITQ GET/PUT status
            print_check "XMITQ GET/PUT status"
            if [[ "$xmit_get" == "ENABLED" && "$xmit_put" == "ENABLED" ]]; then
                print_pass "GET/PUT enabled"
            else
                print_fail "GET($xmit_get) PUT($xmit_put)"
            fi
            
            print_check "XMITQ channel attached"
            if [[ "$ipprocs" -gt 0 ]]; then
                print_pass "Yes (IPPROCS=$ipprocs)"
            else
                print_warn "No (IPPROCS=0) - triggered channel?"
            fi
        fi
        
        # If channel exists, validate it
        if [[ -n "$channel" ]]; then
            # Get channel definition details
            local chl_def=$(check_channel_definition "$qmgr" "$channel")
            local chl_conname=$(echo "$chl_def" | cut -d: -f1)
            local chl_maxmsgl=$(echo "$chl_def" | cut -d: -f2)
            
            print_check "Channel '$channel'"
            local status_full=$(check_channel_status "$qmgr" "$channel")
            local status=$(echo "$status_full" | cut -d: -f1)
            local msgs=$(echo "$status_full" | cut -d: -f2)
            
            # Store for summary
            ROUTE_CHANNEL_STATUS[$i]="$status"
            ROUTE_CHANNEL_INFO[$i]="$chl_conname"
            
            case "$status" in
                RUNNING)
                    print_pass "RUNNING"
                    print_info "Target: $chl_conname"
                    [[ -n "$msgs" ]] && print_info "Messages: $msgs"
                    ;;
                RETRYING)
                    print_fail "RETRYING (connection issue)"
                    print_info "Target: $chl_conname"
                    ;;
                STOPPED)
                    print_fail "STOPPED"
                    print_info "Run: START CHANNEL($channel)"
                    ;;
                INACTIVE)
                    print_warn "INACTIVE (triggered?)"
                    print_info "Target: $chl_conname"
                    ;;
                BINDING|STARTING)
                    print_warn "$status (initializing)"
                    print_info "Target: $chl_conname"
                    ;;
                *)
                    print_warn "Status: $status"
                    ;;
            esac
        fi
    done
}

#==============================================================================
# Summary
#==============================================================================

print_summary() {
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local box_width=104
    
    echo ""
    echo -e "${BLUE}╔$(printf '═%.0s' $(seq 1 $box_width))╗${NC}"
    printf "${BLUE}║${NC}%*s${BOLD}MQ ROUTE VALIDATION REPORT${NC}%*s${BLUE}║${NC}\n" 39 "" 39 ""
    printf "${BLUE}║${NC}%*s%s%*s${BLUE}║${NC}\n" 42 "" "$timestamp" 43 ""
    echo -e "${BLUE}╚$(printf '═%.0s' $(seq 1 $box_width))╝${NC}"
    echo ""
    
    # Route Flow Visualization
    echo -e "  ${BOLD}ROUTE:${NC}"
    printf "  "
    for i in "${!ROUTE_QMGRS[@]}"; do
        if [[ $i -eq 0 ]]; then
            printf "${GREEN}●${NC} "
        else
            printf "${CYAN}●${NC} "
        fi
        printf "%s" "${ROUTE_QMGRS[$i]}"
        if [[ $i -lt $((${#ROUTE_QMGRS[@]} - 1)) ]]; then
            printf " ${CYAN}───►${NC} "
        fi
    done
    if [[ -n "$Q_RQMNAME" ]] && ! qmgr_in_config "$Q_RQMNAME" 2>/dev/null; then
        printf " ${CYAN}───►${NC} ${YELLOW}◐${NC} %s ${YELLOW}[EXT]${NC}" "$Q_RQMNAME"
    fi
    echo ""
    echo ""
    
    # Object Status Table - wider columns
    echo -e "  ${BOLD}OBJECTS IN FLOW:${NC}"
    echo "  ┌─────┬────────────┬──────────────────────────────────────┬───────────────┬────────────────────────────────────┐"
    echo "  │ #   │ Type       │ Name                                 │ Status        │ Info                               │"
    echo "  ├─────┼────────────┼──────────────────────────────────────┼───────────────┼────────────────────────────────────┤"
    
    local step=0
    local prev_channel=""
    
    for i in "${!ROUTE_QMGRS[@]}"; do
        local qmgr="${ROUTE_QMGRS[$i]}"
        local queue="${ROUTE_QUEUES[$i]}"
        local qtype="${ROUTE_QTYPES[$i]:-QUEUE}"
        local xmitq="${ROUTE_XMITQS[$i]}"
        local channel="${ROUTE_CHANNELS[$i]}"
        
        # Role - determine based on position and route completeness
        local role="Gateway"
        [[ $i -eq 0 ]] && role="Origin"
        if [[ -z "$xmitq" && $i -eq $((${#ROUTE_QMGRS[@]} - 1)) && -z "$ROUTE_INCOMPLETE" ]]; then
            role="Destination"
        elif [[ -n "$ROUTE_INCOMPLETE" && $i -eq $((${#ROUTE_QMGRS[@]} - 1)) ]]; then
            role="Last hop"
        fi
        
        # QMgr row
        ((step++))
        printf "  │ %-3s │ %-10s │ %-36s │ ${GREEN}%-13s${NC} │ %-34s │\n" "$step" "QMGR" "$qmgr" "[OK] Online" "$role"
        
        # RCVR Channel (from previous hop) - shown AFTER QMgr
        if [[ -n "$prev_channel" ]] && [[ $i -gt 0 ]]; then
            ((step++))
            local rcvr_status=$(check_receiver_status "$qmgr" "$prev_channel")
            local rcvr_color="${GREEN}"
            local rcvr_text="[OK] RUNNING"
            local rcvr_info="Receiving from prev hop"
            case "$rcvr_status" in
                RUNNING*) rcvr_color="${GREEN}"; rcvr_text="[OK] RUNNING"; rcvr_info="Active receiver" ;;
                INACTIVE*) rcvr_color="${YELLOW}"; rcvr_text="[--] WAITING"; rcvr_info="Ready to receive" ;;
                NOT_FOUND*) rcvr_color="${YELLOW}"; rcvr_text="[??] NOTFOUND"; rcvr_info="Check channel name" ;;
                *) rcvr_color="${YELLOW}"; rcvr_text="[--] IDLE"; rcvr_info="Idle" ;;
            esac
            [[ ${#rcvr_info} -gt 34 ]] && rcvr_info="${rcvr_info:0:31}..."
            printf "  │ %-3s │ %-10s │ %-36s │ ${rcvr_color}%-13s${NC} │ %-34s │\n" "$step" "RCVR" "${prev_channel:0:36}" "${rcvr_text:0:13}" "$rcvr_info"
        fi
        
        # Queue (skip pass-through)
        if [[ "$queue" != "(pass-through)" ]]; then
            ((step++))
            local q_info="${ROUTE_QUEUE_INFO[$i]:-}"
            if [[ -z "$q_info" ]]; then
                case "$qtype" in
                    QREMOTE*) q_info="-> ${Q_RQMNAME:-next}" ;;
                    QLOCAL*) 
                        local ql_output=$(run_mqsc "$qmgr" "DISPLAY QLOCAL($queue) CURDEPTH MAXDEPTH IPPROCS OPPROCS" 2>/dev/null)
                        local ql_depth=$(echo "$ql_output" | grep -oP 'CURDEPTH\(\K[0-9]+' | head -1)
                        local ql_max=$(echo "$ql_output" | grep -oP 'MAXDEPTH\(\K[0-9]+' | head -1)
                        local ql_ipprocs=$(echo "$ql_output" | grep -oP 'IPPROCS\(\K[0-9]+' | head -1)
                        local ql_opprocs=$(echo "$ql_output" | grep -oP 'OPPROCS\(\K[0-9]+' | head -1)
                        q_info="D:${ql_depth:-0}/${ql_max:-0} I:${ql_ipprocs:-0} O:${ql_opprocs:-0}"
                        ;;
                    QALIAS*) q_info="-> ${Q_TARGET:-target}" ;;
                    *) q_info="" ;;
                esac
            fi
            [[ ${#q_info} -gt 34 ]] && q_info="${q_info:0:31}..."
            printf "  │ %-3s │ %-10s │ %-36s │ ${GREEN}%-13s${NC} │ %-34s │\n" "$step" "$qtype" "${queue:0:36}" "[OK]" "$q_info"
        fi
        
        # XMITQ
        if [[ -n "$xmitq" ]]; then
            ((step++))
            local xmitq_info="${ROUTE_XMITQ_DEPTHS[$i]:-Depth:0}"
            printf "  │ %-3s │ %-10s │ %-36s │ ${GREEN}%-13s${NC} │ %-34s │\n" "$step" "XMITQ" "${xmitq:0:36}" "[OK] Ready" "$xmitq_info"
        fi
        
        # SDR Channel (outgoing from this QMgr)
        if [[ -n "$channel" ]]; then
            ((step++))
            local chl_status="${ROUTE_CHANNEL_STATUS[$i]:-INACTIVE}"
            local chl_info="${ROUTE_CHANNEL_INFO[$i]:-}"
            local chl_color="${GREEN}"
            local status_text="[OK] RUNNING"
            case "$chl_status" in
                RUNNING*) chl_color="${GREEN}"; status_text="[OK] RUNNING" ;;
                INACTIVE_OK*) chl_color="${GREEN}"; status_text="[OK] READY"; chl_info="Ping OK - ${chl_info}" ;;
                INACTIVE_FAIL*) chl_color="${RED}"; status_text="[!!] NOREACH"; chl_info="Ping FAILED" ;;
                INACTIVE*) chl_color="${YELLOW}"; status_text="[--] IDLE" ;;
                NOT_DEFINED*) chl_color="${RED}"; status_text="[!!] NO DEF" ;;
                RETRYING*) chl_color="${RED}"; status_text="[!!] RETRY" ;;
                STOPPED*) chl_color="${RED}"; status_text="[!!] STOPPED" ;;
                BINDING*|STARTING*) chl_color="${YELLOW}"; status_text="[..] START" ;;
                *) chl_color="${YELLOW}"; status_text="[--] IDLE" ;;
            esac
            [[ ${#chl_info} -gt 34 ]] && chl_info="${chl_info:0:31}..."
            printf "  │ %-3s │ %-10s │ %-36s │ ${chl_color}%-13s${NC} │ %-34s │\n" "$step" "SDR" "${channel:0:36}" "${status_text:0:13}" "$chl_info"
        fi
        
        # Store channel for next hop's RCVR display
        prev_channel="$channel"
        
        # Row separator between hops
        if [[ $i -lt $((${#ROUTE_QMGRS[@]} - 1)) ]]; then
            echo "  ├─────┼────────────┼──────────────────────────────────────┼───────────────┼────────────────────────────────────┤"
        fi
    done
    
    # Show external destination (QMgr not in config = external boundary, NOT an error)
    if [[ -n "$ROUTE_INCOMPLETE" ]]; then
        echo "  ├─────┼────────────┼──────────────────────────────────────┼───────────────┼────────────────────────────────────┤"
        ((step++))
        local incomplete_info=""
        local incomplete_status=""
        local incomplete_color="${CYAN}"
        case "$ROUTE_INCOMPLETE_REASON" in
            NOT_IN_CONFIG) 
                # External QMgr - this is the boundary, NOT an error
                incomplete_info="External destination (boundary)"
                incomplete_status="[EXT]"
                incomplete_color="${CYAN}"
                ;;
            NO_XMITQ) 
                # This IS an error - routing issue
                incomplete_info="No XMITQ defined on gateway"
                incomplete_status="[NO XMIT]"
                incomplete_color="${RED}"
                ;;
            *) 
                incomplete_info="Route boundary"
                incomplete_status="[EXT]"
                incomplete_color="${CYAN}"
                ;;
        esac
        printf "  │ %-3s │ %-10s │ %-36s │ ${incomplete_color}%-13s${NC} │ %-34s │\n" "$step" "QMGR" "${ROUTE_INCOMPLETE:0:36}" "$incomplete_status" "$incomplete_info"
    # External destination (no issues)
    elif [[ -n "$Q_RQMNAME" ]] && ! qmgr_in_config "$Q_RQMNAME" 2>/dev/null; then
        echo "  ├─────┼────────────┼──────────────────────────────────────┼───────────────┼────────────────────────────────────┤"
        ((step++))
        printf "  │ %-3s │ %-10s │ %-36s │ ${CYAN}%-13s${NC} │ %-34s │\n" "$step" "QMGR" "${Q_RQMNAME:0:36}" "[EXT]" "External destination (boundary)"
    fi
    
    echo "  └─────┴────────────┴──────────────────────────────────────┴───────────────┴────────────────────────────────────┘"
    echo ""
    
    # Show route issues if any (but NOT NOT_IN_CONFIG as that's external boundary)
    local real_issues=()
    for issue in "${ROUTE_ISSUES[@]}"; do
        local issue_type=$(echo "$issue" | cut -d'|' -f1)
        # Skip CONFIG issues - external boundary is not an error
        [[ "$issue_type" == "CONFIG" ]] && continue
        real_issues+=("$issue")
    done
    
    if [[ ${#real_issues[@]} -gt 0 ]]; then
        echo -e "  ${RED}${BOLD}ISSUES DETECTED:${NC}"
        for issue in "${real_issues[@]}"; do
            local issue_type=$(echo "$issue" | cut -d'|' -f1)
            local issue_qmgr=$(echo "$issue" | cut -d'|' -f2)
            local issue_desc=$(echo "$issue" | cut -d'|' -f3-)
            echo -e "  ${RED}✗${NC} [$issue_type] on $issue_qmgr: $issue_desc"
        done
        echo ""
    fi
    
    # Health Summary Bar
    local health_pct=0
    [[ $TOTAL_CHECKS -gt 0 ]] && health_pct=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))
    
    echo -e "  ${BOLD}HEALTH:${NC} $PASSED_CHECKS passed, $FAILED_CHECKS failed, $WARNING_CHECKS warnings"
    printf "  ["
    local bar_width=50
    local filled=$((health_pct * bar_width / 100))
    if [[ $health_pct -ge 90 ]]; then printf "${GREEN}"; elif [[ $health_pct -ge 70 ]]; then printf "${YELLOW}"; else printf "${RED}"; fi
    for ((j=0; j<filled; j++)); do printf "█"; done
    printf "${NC}"
    for ((j=filled; j<bar_width; j++)); do printf "░"; done
    printf "] %d%%\n" "$health_pct"
    echo ""
    
    # Final Verdict - fixed width 100 chars inside box
    local verdict_width=100
    
    # External boundary (NOT_IN_CONFIG) is NOT an error - it's expected
    local route_is_healthy=true
    if [[ $FAILED_CHECKS -gt 0 ]]; then
        route_is_healthy=false
    elif [[ -n "$ROUTE_INCOMPLETE" && "$ROUTE_INCOMPLETE_REASON" == "NO_XMITQ" ]]; then
        # Routing issue - this IS an error
        route_is_healthy=false
    fi
    # NOT_IN_CONFIG is external boundary - NOT an error
    
    if $route_is_healthy; then
        echo -e "  ${GREEN}┏$(printf '━%.0s' $(seq 1 $verdict_width))┓${NC}"
        if [[ -n "$ROUTE_INCOMPLETE" && "$ROUTE_INCOMPLETE_REASON" == "NOT_IN_CONFIG" ]]; then
            printf "  ${GREEN}┃  ✓  ROUTE HEALTHY - Validated to external boundary (%s)%*s┃${NC}\n" "${ROUTE_INCOMPLETE:0:20}" $((24 - ${#ROUTE_INCOMPLETE})) ""
        else
            printf "  ${GREEN}┃  ✓  ROUTE HEALTHY - All objects validated successfully%*s┃${NC}\n" 45 ""
        fi
        echo -e "  ${GREEN}┗$(printf '━%.0s' $(seq 1 $verdict_width))┛${NC}"
        return 0
    elif [[ -n "$ROUTE_INCOMPLETE" && "$ROUTE_INCOMPLETE_REASON" == "NO_XMITQ" ]]; then
        echo -e "  ${RED}┏$(printf '━%.0s' $(seq 1 $verdict_width))┓${NC}"
        printf "  ${RED}┃  ✗  ROUTE BROKEN - Missing XMITQ on gateway for destination%*s┃${NC}\n" 40 ""
        echo -e "  ${RED}┗$(printf '━%.0s' $(seq 1 $verdict_width))┛${NC}"
        return 1
    else
        echo -e "  ${RED}┏$(printf '━%.0s' $(seq 1 $verdict_width))┓${NC}"
        printf "  ${RED}┃  ✗  ROUTE ISSUES - %3d problem(s) require attention%*s┃${NC}\n" "$FAILED_CHECKS" 47 ""
        echo -e "  ${RED}┗$(printf '━%.0s' $(seq 1 $verdict_width))┛${NC}"
        return 1
    fi
}

#==============================================================================
# Main
#==============================================================================

show_usage() {
    cat << 'EOF'
MQ Pre-flight Route Validator - Dynamic Route Discovery
========================================================

Automatically discovers and validates the complete message route.

Usage:
  ./mq_preflight_validator.sh --qmgr <QMGR> --queue <QUEUE>

Options:
  --qmgr <name>       Starting queue manager (required)
  --queue <name>      Target queue name (required)
  --config <file>     Config file (default: mq_config.yaml)
  --verbose, -v       Show detailed validation output
  -h, --help          Show this help

Example:
  ./mq_preflight_validator.sh --qmgr APEX.C1.MEM1 --queue APEX.TO.OMNI.WIRE.REQ
  ./mq_preflight_validator.sh --qmgr APEX.C1.MEM1 --queue APEX.TO.OMNI.WIRE.REQ -v

Config file format (mq_config.yaml):
  queue_managers:
    QMGR_NAME:
      host: "hostname"
      port: 1414
      channel: "ADMIN.SVRCONN"
      ssl_cipher_spec: "ANY_TLS12_OR_HIGHER"  # optional
      ssl_key_repository: "/path/to/keystore"  # optional
EOF
}

main() {
    local START_QMGR=""
    local START_QUEUE=""
    QUIET_MODE=true  # Default to summary only
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --qmgr) START_QMGR="$2"; shift 2 ;;
            --queue) START_QUEUE="$2"; shift 2 ;;
            --config) CONFIG_FILE="$2"; shift 2 ;;
            --verbose|-v) QUIET_MODE=false; shift ;;
            -h|--help) show_usage; exit 0 ;;
            *) echo "Unknown option: $1"; show_usage; exit 1 ;;
        esac
    done
    
    if [[ -z "$START_QMGR" || -z "$START_QUEUE" ]]; then
        echo "Error: --qmgr and --queue are required"
        echo ""
        show_usage
        exit 1
    fi
    
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file not found: $CONFIG_FILE"
        exit 1
    fi
    
    # Phase 1: Discover route (quiet)
    discover_route "$START_QMGR" "$START_QUEUE"
    
    # Check if route was discovered
    if [[ ${#ROUTE_QMGRS[@]} -eq 0 ]]; then
        echo ""
        echo -e "${RED}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
        echo -e "${RED}┃  ✗ FAILED - QMgr '$START_QMGR' not found in config                       ┃${NC}"
        echo -e "${RED}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
        return 1
    fi
    
    # Phase 2: Validate route
    validate_route
    
    # Phase 3: Summary (always shown)
    print_summary
}

main "$@"
