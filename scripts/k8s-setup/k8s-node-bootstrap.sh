#!/bin/bash
# Enhance script fault tolerance: -e (exit on error), -u (error on undefined variable), -o pipefail (pipe error propagation)
set -euo pipefail

# Define logging functions: hierarchical output to reduce redundancy
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

# Configuration for retry and state tracking
RETRY_COUNT=3  # Retry 3 times for network failures
STATE_FILE="$HOME/k8s/install/node_init_state.log"
SSH_COMMON_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o ConnectionAttempts=$RETRY_COUNT"
SSH_PASS_OPTS="$SSH_COMMON_OPTS -o PreferredAuthentications=password -o PubkeyAuthentication=no"

# Create state file if not exists
touch "$STATE_FILE"

# Check if node has been initialized successfully
is_node_completed() {
  local NODE_IP=$1
  grep -q "^COMPLETED: $NODE_IP$" "$STATE_FILE" 2>/dev/null
}

# Mark node as completed
mark_node_completed() {
  local NODE_IP=$1
  # Remove existing entry first
  sed -i "/^COMPLETED: $NODE_IP$/d" "$STATE_FILE" 2>/dev/null
  echo "COMPLETED: $NODE_IP" >> "$STATE_FILE"
}

# Update hosts file (local execution)
update_hosts_file_local() {
  local hosts_file="/etc/hosts"
  local need_update=0

  # Check if any entry is missing
  for entry in "${HOSTS_ENTRIES[@]}"; do
    [ -z "$entry" ] && continue
    if ! grep -qxF "$entry" "$hosts_file" 2>/dev/null; then
      need_update=1
      break
    fi
  done

  if [ "$need_update" -eq 1 ]; then
    log_info "Updating local /etc/hosts..."
    # Remove duplicate entries first (sudo to ensure permission)
    for entry in "${HOSTS_ENTRIES[@]}"; do
      [ -z "$entry" ] && continue
      local escaped_entry=$(echo "$entry" | sed 's/[\/&]/\\&/g')
      sudo sed -i "/$escaped_entry/d" "$hosts_file" 2>/dev/null
    done
    # Critical Fix: Use sudo tee to ensure write permission
    echo -e "$HOSTS_BLOCK" | sudo tee -a "$hosts_file" > /dev/null
    log_info "Local /etc/hosts updated successfully"
  else
    log_info "Local /etc/hosts is already up to date"
  fi
}

# ---------------------------------------------------------
# Step 1: Load Configuration File
# ---------------------------------------------------------
CONF_FILE="$HOME/k8s/install/cluster.env"
[ ! -f "$CONF_FILE" ] && log_error "Configuration file $CONF_FILE does not exist!"
log_info "Loading configuration file: $CONF_FILE"
source "$CONF_FILE" > /dev/null 2>&1 || log_error "Failed to load configuration file!"

# Validate critical variables
if [ -z "${HOSTS_ENTRIES[*]}" ] || [ -z "$HOSTS_BLOCK" ] || [ -z "$NODE_PASSWORD" ]; then
  log_error "HOSTS_ENTRIES/HOSTS_BLOCK/NODE_PASSWORD is empty in $CONF_FILE!"
fi

# Check/generate SSH key pair (non-interactive)
if [ ! -f "$HOME/.ssh/id_rsa" ]; then
  log_info "Generating SSH key pair (passwordless)..."
  ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa > /dev/null 2>&1
fi

# ---------------------------------------------------------
# Step 2: Jump Server Local Configuration
# ---------------------------------------------------------
configure_jump_server() {
  log_info "Starting Jump Server (local) configuration..."

  # 1. Update local hosts file
  update_hosts_file_local

  # 2. Configure passwordless sudo
  if [ ! -f /etc/sudoers.d/dadmin ]; then
    log_info "Configuring local passwordless sudo..."
    echo "dadmin ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/dadmin > /dev/null
    sudo chmod 0440 /etc/sudoers.d/dadmin
    sudo visudo -c -f /etc/sudoers.d/dadmin > /dev/null 2>&1 || log_error "sudoers configuration syntax error!"
  fi

  # 3. Install sshpass if missing
  if ! command -v sshpass &> /dev/null; then
    log_info "Installing sshpass..."
    sudo apt update -qq > /dev/null 2>&1
    sudo apt install -y sshpass > /dev/null 2>&1
  fi

  # 4. Download Zscaler CA certificate
  if [ ! -f "/tmp/zscaler_root_ca.crt" ]; then
    log_info "Downloading Zscaler CA certificate..."
    openssl s_client -showcerts -connect pkgs.k8s.io:443 </dev/null 2>&1 | \
    sed -n '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > /tmp/zscaler_root_ca.crt || \
    log_error "Failed to download Zscaler CA certificate!"
  fi

  # 5. Download K8s GPG key
  if [ ! -f "/tmp/kubernetes-apt-keyring.gpg" ]; then
    log_info "Downloading K8s GPG key..."
    if ! curl -fsSL -k https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | \
    gpg --dearmor -o /tmp/kubernetes-apt-keyring.gpg > /dev/null 2>&1; then
      rm -f /tmp/kubernetes-apt-keyring.gpg
      log_error "Failed to download K8s GPG key!"
    fi
  fi

  # 6. Inject CA certificate to trust store
  log_info "Injecting CA certificate to system trust store..."
  sudo cp /tmp/zscaler_root_ca.crt /usr/local/share/ca-certificates/zscaler.crt > /dev/null
  sudo update-ca-certificates > /dev/null 2>&1

  # 7. Install kubectl if missing
  if ! command -v kubectl &> /dev/null; then
    log_info "Installing kubectl..."
    sudo mkdir -p -m 755 /etc/apt/keyrings > /dev/null
    sudo cp /tmp/kubernetes-apt-keyring.gpg /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | \
    sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
    sudo apt-get update -qq > /dev/null 2>&1
    sudo apt-get install -y kubectl > /dev/null 2>&1
    sudo apt-mark hold kubectl > /dev/null
  fi
}

# ---------------------------------------------------------
# Step 3: Remote Node Provisioning Function (full passwordless + retry + idempotent)
# ---------------------------------------------------------
bootstrap_node() {
  local NODE=$1
  local NODE_USER=$(echo "$NODE" | cut -d'@' -f1)
  local NODE_IP=$(echo "$NODE" | cut -d'@' -f2)

  # Skip if node is already completed
  if is_node_completed "$NODE_IP"; then
    log_info "--- Skipping completed node: $NODE_IP ---"
    return 0
  fi

  # Critical Fix 1: Get hostname via sshpass (no password prompt) with retry
  local NODE_HOSTNAME
  NODE_HOSTNAME=$(sshpass -p "$NODE_PASSWORD" ssh $SSH_PASS_OPTS "$NODE" "hostname" 2>/dev/null || echo "$NODE_IP")

  # Node identifier header (simplified)
  log_info "--- Processing remote node: $NODE_IP ($NODE_HOSTNAME) ---"

  # A. Configure SSH passwordless login (sshpass to avoid prompt)
  log_info "[Node: $NODE_IP] Configuring SSH passwordless login..."
  sshpass -p "$NODE_PASSWORD" ssh-copy-id $SSH_COMMON_OPTS -i "$HOME/.ssh/id_rsa.pub" "$NODE" > /dev/null 2>&1 || \
  log_error "[Node: $NODE_IP] SSH passwordless configuration failed after $RETRY_COUNT retries!"

  # B. Configure passwordless sudo (sshpass to avoid prompt)
  log_info "[Node: $NODE_IP] Configuring passwordless sudo..."
  sshpass -p "$NODE_PASSWORD" ssh $SSH_PASS_OPTS "$NODE" \
  "echo '$NODE_PASSWORD' | sudo -S bash -c 'echo \"$NODE_USER ALL=(ALL) NOPASSWD: ALL\" > /etc/sudoers.d/$NODE_USER && chmod 0440 /etc/sudoers.d/$NODE_USER && visudo -c -f /etc/sudoers.d/$NODE_USER'" > /dev/null 2>&1

  # C. Create ~/.hushlogin (sshpass to avoid prompt)
  log_info "[Node: $NODE_IP] Configuring ~/.hushlogin..."
  sshpass -p "$NODE_PASSWORD" ssh $SSH_PASS_OPTS "$NODE" \
  "touch ~/.hushlogin && chmod 644 ~/.hushlogin" > /dev/null 2>&1

  # D. Copy CA/GPG files (sshpass to avoid prompt for scp)
  log_info "[Node: $NODE_IP] Copying CA/GPG files..."
  sshpass -p "$NODE_PASSWORD" scp $SSH_COMMON_OPTS \
  /tmp/zscaler_root_ca.crt /tmp/kubernetes-apt-keyring.gpg "$NODE:/tmp/" > /dev/null 2>&1 || \
  log_error "[Node: $NODE_IP] File copy failed after $RETRY_COUNT retries!"

  # E. Execute remote initialization (use sshpass for first-time SSH after copy-id)
  log_info "[Node: $NODE_IP] Executing remote initialization..."

  # Convert HOSTS_ENTRIES to newline-separated string (trim empty lines)
  local hosts_entries_newline=$(printf "%s\n" "${HOSTS_ENTRIES[@]}" | sed '/^$/d')

  # Critical Fix 2: Use sshpass for remote execution to avoid prompt with retry
  sshpass -p "$NODE_PASSWORD" ssh $SSH_COMMON_OPTS "$NODE" "bash -s" << EOF
    set -euo pipefail
    # Remote logging with node identifier (simplified)
    log_remote() {
      local REMOTE_IP=\$(hostname -I | awk '{print \$1}')
      echo -e "\033[32m[REMOTE] [Node: \$REMOTE_IP] $(date +'%Y-%m-%d %H:%M:%S'): \$1\033[0m"
    }

    # Update remote hosts file (core fix: remove break to check all entries + ensure sudo write)
    update_hosts_file_remote() {
      local hosts_file="/etc/hosts"
      local need_update=0
      local hosts_entries="\$1"
      local hosts_block="\$2"

      # Check ALL entries (fix: no break, ensure need_update is set)
      while IFS= read -r entry; do
        [ -z "\$entry" ] && continue
        if ! grep -qxF "\$entry" "\$hosts_file" 2>/dev/null; then
          need_update=1
        fi
      done <<< "\$hosts_entries"

      if [ "\$need_update" -eq 1 ]; then
        log_remote "Updating /etc/hosts..."
        # Remove duplicates (sudo for permission)
        while IFS= read -r entry; do
          [ -z "\$entry" ] && continue
          local escaped_entry=\$(echo "\$entry" | sed 's/[\/&]/\\&/g')
          sudo sed -i "/\$escaped_entry/d" "\$hosts_file" 2>/dev/null
        done <<< "\$hosts_entries"
        # Critical Fix: Use echo -e with sudo tee to ensure proper line breaks and write permission
        echo -e "\$hosts_block" | sudo tee -a "\$hosts_file" > /dev/null
        log_remote "/etc/hosts updated successfully"
      else
        log_remote "/etc/hosts is already up to date"
      fi
    }

    # Execute hosts update (pass parameters)
    update_hosts_file_remote "$hosts_entries_newline" "$HOSTS_BLOCK"

    # Inject CA certificate
    log_remote "Injecting CA certificate and updating system..."
    sudo mv /tmp/zscaler_root_ca.crt /usr/local/share/ca-certificates/zscaler.crt > /dev/null
    sudo update-ca-certificates > /dev/null 2>&1
    sudo apt-get update -y -qq > /dev/null 2>&1
    sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq > /dev/null 2>&1

    # K8s OS Tuning
    log_remote "Configuring K8s system parameters..."
    sudo swapoff -a > /dev/null
    sudo sed -i '/swap/s/^/#/' /etc/fstab > /dev/null 2>&1
    echo -e "overlay\nbr_netfilter" | sudo tee /etc/modules-load.d/k8s.conf > /dev/null
    sudo modprobe overlay > /dev/null 2>&1
    sudo modprobe br_netfilter > /dev/null 2>&1
    cat <<ETC | sudo tee /etc/sysctl.d/k8s.conf > /dev/null
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
ETC
    sudo sysctl --system > /dev/null 2>&1

    # Install containerd
    log_remote "Installing and configuring containerd..."
    sudo apt-get install -y containerd > /dev/null 2>&1
    sudo mkdir -p /etc/containerd > /dev/null
    containerd config default | sudo tee /etc/containerd/config.toml > /dev/null
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml > /dev/null
    sudo systemctl restart containerd > /dev/null 2>&1
    sudo systemctl enable containerd > /dev/null 2>&1

    # Install K8s components
    log_remote "Installing K8s components (kubelet/kubeadm/kubectl)..."
    sudo apt-get install -y apt-transport-https ca-certificates curl gnupg > /dev/null 2>&1
    sudo mkdir -p -m 755 /etc/apt/keyrings > /dev/null
    sudo mv /tmp/kubernetes-apt-keyring.gpg /etc/apt/keyrings/kubernetes-apt-keyring.gpg > /dev/null
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list > /dev/null
    sudo apt-get update -y -qq > /dev/null 2>&1
    sudo apt-get install -y kubelet kubeadm kubectl > /dev/null 2>&1
    sudo apt-mark hold kubelet kubeadm kubectl > /dev/null

    # Disable firewall
    log_remote "Disabling firewall..."
    sudo ufw disable > /dev/null 2>&1 || true
EOF

  # Mark node as completed if all steps succeed
  mark_node_completed "$NODE_IP"
  log_info "[Node: $NODE_IP] Remote initialization completed"
  log_info "--- Finished processing remote node: $NODE_IP ---"
}

# ---------------------------------------------------------
# Step 4: Execution Flow
# ---------------------------------------------------------
log_info "==================== Starting K8s Cluster Initialization ===================="
log_info "State tracking file: $STATE_FILE"
log_info "Retry count for network failures: $RETRY_COUNT"

configure_jump_server

# Process all remote nodes (skip completed ones)
for NODE in "${ALL_NODES[@]}"; do
  bootstrap_node "$NODE"
done

log_info "==================== K8s Cluster Initialization Completed ===================="
log_info "Completed nodes list:"
grep "^COMPLETED:" "$STATE_FILE" | awk '{print $2}'
log_info "Next step: Configure kube-vip for VIP functionality"