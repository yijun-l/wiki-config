#!/bin/bash
set -euo pipefail

# Define structured logging functions with timestamps and color coding
log_info() {
  echo -e "\033[32m[INFO] $(date +'%Y-%m-%d %H:%M:%S'): $1\033[0m"
}
log_warn() {
  echo -e "\033[33m[WARN] $(date +'%Y-%m-%d %H:%M:%S'): $1\033[0m"
}
log_error() {
  echo -e "\033[31m[ERROR] $(date +'%Y-%m-%d %H:%M:%S'): $1\033[0m"
  exit 1
}

# ---------------------------------------------------------
# Helper Function: Check if HA services are healthy on node
# Arguments:
#   $1 - Node address (IP/hostname)
#   $2 - Node IP (for VIP check on primary)
#   $3 - VIP address
#   $4 - Is primary node (true/false)
# Returns:
#   0 = healthy, 1 = unhealthy
# ---------------------------------------------------------
is_ha_healthy() {
  local NODE="$1"
  local NODE_IP="$2"
  local VIP="$3"
  local IS_PRIMARY="$4"

  # Check if HAProxy/Keepalived are running
  local SERVICE_HEALTH=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$NODE" << EOF
    set -e
    if sudo systemctl is-active --quiet haproxy && sudo systemctl is-active --quiet keepalived; then
        echo "running"
    else
        echo "stopped"
    fi
EOF
  )

  if [ "$SERVICE_HEALTH" != "running" ]; then
    return 1
  fi

  # Check if configuration files exist and are valid (basic check)
  local CONFIG_EXISTS=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$NODE" << EOF
    set -e
    if [ -f /etc/haproxy/haproxy.cfg ] && [ -f /etc/keepalived/keepalived.conf ]; then
        echo "exists"
    else
        echo "missing"
    fi
EOF
  )

  if [ "$CONFIG_EXISTS" != "exists" ]; then
    return 1
  fi

  # Check VIP binding on primary node (skip for backup)
  if [ "$IS_PRIMARY" = "true" ]; then
    local VIP_BOUND=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$NODE" << EOF
      set -e
      INTERFACE=\$(ip route get 8.8.8.8 | awk '{print \$5}')
      [ -z "\$INTERFACE" ] && INTERFACE="ens33"
      if ip addr show \$INTERFACE | grep -q "$VIP"; then
          echo "bound"
      else
          echo "unbound"
      fi
EOF
    )
    if [ "$VIP_BOUND" != "bound" ]; then
      return 1
    fi
  fi

  return 0
}

# ---------------------------------------------------------
# Load Configuration File
# ---------------------------------------------------------
CONF_FILE="$HOME/k8s/install/cluster.env"
[ ! -f "$CONF_FILE" ] && log_error "Configuration file $CONF_FILE does not exist"
log_info "Loading configuration from: $CONF_FILE"
source "$CONF_FILE"

# Validate required config variables
REQUIRED_VARS=("MASTERS" "MASTER_IPS" "VIP" "VIP_PORT" "KEEPALIVED_AUTH_PASS")
for VAR in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!VAR:-}" ]; then
    log_error "Required variable \$$VAR is empty in $CONF_FILE"
  fi
done

# ---------------------------------------------------------
# Clean Up Only Unhealthy Nodes (Idempotent Cleanup)
# ---------------------------------------------------------
log_info "====================================================="
log_info "PHASE 1/3: Clean Up Unhealthy HA Configurations"
log_info "====================================================="

MASTER_PRIMARY_IP=$(echo "${MASTER_IPS[0]}" | awk '{print $1}')

for i in "${!MASTERS[@]}"; do
  NODE="${MASTERS[$i]}"
  NODE_NAME=$(echo "${MASTER_IPS[$i]}" | awk '{print $2}')
  NODE_IP=$(echo "${MASTER_IPS[$i]}" | awk '{print $1}')
  IS_PRIMARY="false"
  [ "$NODE_IP" = "$MASTER_PRIMARY_IP" ] && IS_PRIMARY="true"

  # Skip cleanup if node is healthy (idempotency core)
  if is_ha_healthy "$NODE" "$NODE_IP" "$VIP" "$IS_PRIMARY"; then
    log_warn "Node $NODE_NAME is healthy - skipping cleanup"
    continue
  fi

  log_info "Cleaning up unhealthy node: $NODE ($NODE_NAME)..."
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$NODE" << 'EOF'
    set -e
    # Stop services (ignore if already stopped)
    sudo systemctl stop haproxy keepalived > /dev/null 2>&1 || true
    sudo systemctl disable haproxy keepalived > /dev/null 2>&1 || true

    # Remove invalid configuration files (if exist)
    sudo rm -f /etc/haproxy/haproxy.cfg /etc/keepalived/keepalived.conf || true

    # Reinstall only if packages are broken/missing (avoid redundant purge)
    if ! dpkg -s haproxy keepalived > /dev/null 2>&1; then
        sudo apt-get update -qq > /dev/null
        sudo apt-get install -y -qq haproxy keepalived > /dev/null
    else
        # Repair packages if needed (lighter than purge)
        sudo apt-get install -y -qq --reinstall haproxy keepalived > /dev/null
    fi
EOF
  log_info "Cleanup completed for $NODE_NAME"
done

# ---------------------------------------------------------
# Deploy HAProxy/Keepalived Only to Unhealthy Nodes
# ---------------------------------------------------------
log_info "====================================================="
log_info "PHASE 2/3: Deploy HA Services (HAProxy/Keepalived)"
log_info "====================================================="

for i in "${!MASTERS[@]}"; do
  NODE="${MASTERS[$i]}"
  NODE_NAME=$(echo "${MASTER_IPS[$i]}" | awk '{print $2}')
  NODE_IP=$(echo "${MASTER_IPS[$i]}" | awk '{print $1}')
  PRIORITY=$((100 - i * 10))  # Priority decreases by 10 for each subsequent node
  IS_PRIMARY="false"
  [ "$NODE_IP" = "$MASTER_PRIMARY_IP" ] && IS_PRIMARY="true"

  # Skip deployment if node is already healthy (idempotency core)
  if is_ha_healthy "$NODE" "$NODE_IP" "$VIP" "$IS_PRIMARY"; then
    log_warn "Node $NODE_NAME is already healthy - skipping deployment"
    continue
  fi

  log_info ""
  log_info "-----------------------------------------------------"
  log_info "Configuring unhealthy node: $NODE ($NODE_NAME) | Priority: $PRIORITY"
  log_info "-----------------------------------------------------"

  # Generate HAProxy backend configuration
  HAPROXY_BACKENDS=""
  for j in "${!MASTER_IPS[@]}"; do
    M_IP=$(echo "${MASTER_IPS[$j]}" | awk '{print $1}')
    M_NAME=$(echo "${MASTER_IPS[$j]}" | awk '{print $2}')
    HAPROXY_BACKENDS+="    server ${M_NAME} ${M_IP}:${VIP_PORT} check fall 3 rise 2\n"
  done

  # Deploy HA services to target node
  ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$NODE" << EOF
    set -e
    # Auto-detect network interface (fallback to ens33)
    INTERFACE=\$(ip route get 8.8.8.8 | awk '{print \$5}')
    [ -z "\$INTERFACE" ] && INTERFACE="ens33"

    # Write HAProxy configuration (overwrite only if unhealthy)
    sudo bash -c 'cat > /etc/haproxy/haproxy.cfg' <<HAC
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon
defaults
    log     global
    mode    tcp
    option  tcplog
    timeout connect 5s
    timeout client  50s
    timeout server  50s
frontend k8s-api
    bind *:${VIP_PORT}
    default_backend k8s-masters
backend k8s-masters
    balance roundrobin
    option tcp-check
$(echo -e "$HAPROXY_BACKENDS")
HAC

    # Write Keepalived configuration (BACKUP mode with nopreempt)
    sudo bash -c 'cat > /etc/keepalived/keepalived.conf' <<KPC
vrrp_instance VI_1 {
    state BACKUP
    interface \$INTERFACE
    virtual_router_id 51
    priority ${PRIORITY}
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass ${KEEPALIVED_AUTH_PASS}
    }
    virtual_ipaddress {
        ${VIP}/32
    }
    nopreempt
    garp_master_delay 1
}
KPC

    # Fix permissions and restart services
    sudo chown root:root /etc/haproxy/haproxy.cfg /etc/keepalived/keepalived.conf
    sudo systemctl daemon-reload
    sudo systemctl start haproxy keepalived
    sudo systemctl enable haproxy keepalived

    # Validate service status
    if ! sudo systemctl is-active --quiet haproxy; then
        echo "HAProxy service failed to start. Recent logs:"
        sudo journalctl -u haproxy --no-pager | tail -5
        exit 1
    fi
    if ! sudo systemctl is-active --quiet keepalived; then
        echo "Keepalived service failed to start. Recent logs:"
        sudo journalctl -u keepalived --no-pager | tail -5
        exit 1
    fi

    # Verify VIP binding (only on primary master node)
    if [ "${IS_PRIMARY}" = "true" ]; then
        sleep 3
        if ip addr show \$INTERFACE | grep -q "${VIP}"; then
            echo "$NODE_NAME (primary node) configured successfully - VIP bound"
        else
            echo "$NODE_NAME (primary node) VIP binding failed"
            exit 1
        fi
    else
        echo "$NODE_NAME (backup node) configured successfully (no VIP expected)"
    fi
EOF

  # Recheck health after deployment
  if is_ha_healthy "$NODE" "$NODE_IP" "$VIP" "$IS_PRIMARY"; then
    log_info "Deployment completed and verified for $NODE_NAME"
  else
    log_error "Deployment completed but node $NODE_NAME is still unhealthy"
  fi
done

# ---------------------------------------------------------
# Post-Deployment Validation (All Nodes)
# ---------------------------------------------------------
log_info "====================================================="
log_info "PHASE 3/3: Post-Deployment Validation"
log_info "====================================================="

# Validate all nodes are healthy
ALL_HEALTHY="true"
for i in "${!MASTERS[@]}"; do
  NODE="${MASTERS[$i]}"
  NODE_NAME=$(echo "${MASTER_IPS[$i]}" | awk '{print $2}')
  NODE_IP=$(echo "${MASTER_IPS[$i]}" | awk '{print $1}')
  IS_PRIMARY="false"
  [ "$NODE_IP" = "$MASTER_PRIMARY_IP" ] && IS_PRIMARY="true"

  if ! is_ha_healthy "$NODE" "$NODE_IP" "$VIP" "$IS_PRIMARY"; then
    log_warn "Node $NODE_NAME is still unhealthy after deployment"
    ALL_HEALTHY="false"
  else
    log_info "Node $NODE_NAME is healthy"
  fi
done

if [ "$ALL_HEALTHY" = "true" ]; then
  log_info "All HA nodes are healthy!"
else
  log_error "Some HA nodes are still unhealthy - check logs above"
fi

log_info "====================================================="
log_info "Validation commands for manual verification:"
log_info "  1. Check VIP on primary node: ssh $NODE@$MASTER_PRIMARY_IP 'ip addr show ens33 | grep $VIP'"
log_info "  2. Check backup node services: ssh $NODE@${MASTERS[1]} 'sudo systemctl status keepalived'"
log_info "  3. Failover test: Stop Keepalived on primary node and verify VIP takeover"
log_info "====================================================="