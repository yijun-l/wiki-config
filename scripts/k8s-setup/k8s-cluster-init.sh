#!/bin/bash
set -euo pipefail

# Logging functions with timestamp and color coding for better visibility
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

# Core configuration parameters - centralized for easy maintenance
RETRY_COUNT=5                          # Max retries for image pulling operations
STATE_FILE="$HOME/k8s/install/cluster_init_state.log"  # Idempotency state tracking
SSH_COMMON_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 -o ConnectionAttempts=3"
K8S_VERSION="v1.34.3"                  # Explicit Kubernetes version for consistency
POD_CIDR="10.244.0.0/16"               # Flannel-compatible pod network CIDR
FLANNEL_YAML="https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml"

# Create state file directory and file if not exists (critical for idempotency)
mkdir -p "$(dirname "$STATE_FILE")" || log_error "Failed to create state file directory: $(dirname "$STATE_FILE")"
touch "$STATE_FILE"

# -----------------------------------------------------------------------------
# Helper Function: Check if initialization step is completed for a node
# Arguments:
#   $1 - Node hostname/IP
#   $2 - Step name (e.g., image_pull, master_init)
# Returns:
#   0 if completed, 1 if not completed
# -----------------------------------------------------------------------------
is_step_completed() {
  local NODE="$1"
  local STEP="$2"
  grep -q "^COMPLETED: $NODE:$STEP$" "$STATE_FILE" 2>/dev/null
}

# -----------------------------------------------------------------------------
# Helper Function: Mark initialization step as completed for a node
# Arguments:
#   $1 - Node hostname/IP
#   $2 - Step name (e.g., image_pull, master_init)
# Notes:
#   Removes existing entry first to avoid duplicates
# -----------------------------------------------------------------------------
mark_step_completed() {
  local NODE="$1"
  local STEP="$2"
  # Remove existing entry to prevent duplicates
  sed -i "/^COMPLETED: $NODE:$STEP$/d" "$STATE_FILE" 2>/dev/null || true
  echo "COMPLETED: $NODE:$STEP" >> "$STATE_FILE"
}

# -----------------------------------------------------------------------------
# Helper Function: Pull Kubernetes images with retry logic
# Arguments:
#   $1 - Node hostname/IP
# Features:
#   - Idempotent (skips if already completed)
#   - Retries with multiple image repositories
#   - Uses Alibaba Cloud mirror as primary (faster in China)
# -----------------------------------------------------------------------------
pull_images_with_retry() {
  local NODE="$1"

  # Skip if step already completed (idempotency)
  if is_step_completed "$NODE" "image_pull"; then
    log_info "Skipping image pull for $NODE (already completed)"
    return 0
  fi

  log_info "Starting image pull on $NODE (max retries: $RETRY_COUNT)..."
  ssh $SSH_COMMON_OPTS "$NODE" << EOF
    set -euo pipefail
    MAX_RETRIES=$RETRY_COUNT
    COUNT=0
    SUCCESS=false

    # Image repositories (domestic mirror first, official fallback)
    IMAGE_REPOSITORIES=("registry.aliyuncs.com/google_containers" "registry.k8s.io")

    while [ \$COUNT -lt \$MAX_RETRIES ]; do
      for REPO in "\${IMAGE_REPOSITORIES[@]}"; do
        if sudo kubeadm config images pull --kubernetes-version $K8S_VERSION --image-repository "\$REPO"; then
          SUCCESS=true
          break 2  # Exit both loops on success
        fi
      done
      COUNT=\$((COUNT + 1))
      echo "Image pull attempt \$COUNT failed. Retrying in 10 seconds..."
      sleep 10
    done

    if [ "\$SUCCESS" = false ]; then
      echo "Failed to pull Kubernetes images after \$MAX_RETRIES attempts"
      exit 1
    fi
EOF

  # Mark step as completed on successful pull
  mark_step_completed "$NODE" "image_pull"
  log_info "Successfully pulled Kubernetes images on $NODE"
}

# -----------------------------------------------------------------------------
# Helper Function: Validate critical configuration variables
# Arguments:
#   $1 - Path to configuration file
# Validations:
#   - File existence
#   - Required variables presence
#   - SSH connectivity to all nodes
# -----------------------------------------------------------------------------
validate_config() {
  local CONF_FILE="$1"

  # Check configuration file existence
  [ ! -f "$CONF_FILE" ] && log_error "Configuration file not found: $CONF_FILE"

  # Load configuration silently (suppress output)
  log_info "Loading configuration from: $CONF_FILE"
  source "$CONF_FILE" > /dev/null 2>&1 || log_error "Failed to load configuration file: $CONF_FILE"

  # Validate required variables are set
  local REQUIRED_VARS=("MASTERS" "WORKERS" "ALL_NODES" "CP_ENDPOINT")
  for VAR in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!VAR:-}" ]; then
      log_error "Required variable \$$VAR is empty in configuration file: $CONF_FILE"
    fi
  done

  # Validate passwordless SSH access to all nodes
  log_info "Validating SSH connectivity to all nodes..."
  for NODE in "${ALL_NODES[@]}"; do
    if ! ssh $SSH_COMMON_OPTS "$NODE" "echo SSH_OK" >/dev/null 2>&1; then
      log_error "Failed to establish passwordless SSH connection to node: $NODE"
    fi
  done
}

# -----------------------------------------------------------------------------
# Helper Function: Verify Flannel CNI deployment status
# Arguments:
#   $1 - Master node hostname/IP
# Checks:
#   - kube-flannel namespace exists
#   - At least one Flannel pod is in Running state
# -----------------------------------------------------------------------------
check_flannel_status() {
  local NODE="$1"
  ssh $SSH_COMMON_OPTS "$NODE" << EOF
    set -euo pipefail
    # Wait up to 30 seconds for namespace creation
    for i in {1..30}; do
      if kubectl get namespace kube-flannel >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done

    # Check if any Flannel pods are running
    RUNNING_PODS=\$(kubectl get pods -n kube-flannel -l app=flannel -o jsonpath='{.items[*].status.phase}' 2>/dev/null | grep -c Running || true)
    if [ "\$RUNNING_PODS" -eq 0 ]; then
      echo "No Flannel pods in Running state"
      exit 1
    fi
EOF
}

# =============================================================================
# Load and Validate Configuration
# =============================================================================
CONF_FILE="$HOME/k8s/install/cluster.env"
validate_config "$CONF_FILE"

# Extract first master node (control plane init node)
FIRST_MASTER="${MASTERS[0]}"
log_info "Identified first master node: $FIRST_MASTER"
log_info "Control plane endpoint configured: $CP_ENDPOINT"

# =============================================================================
# Pre-pull Kubernetes Images on All Nodes
# =============================================================================
log_info "====================================================="
log_info "PHASE 0: Pre-pulling Kubernetes Images on All Nodes"
log_info "====================================================="

for NODE in "${ALL_NODES[@]}"; do
  pull_images_with_retry "$NODE"
done

# =============================================================================
# Initialize First Master Node (Control Plane)
# =============================================================================
log_info "====================================================="
log_info "PHASE 1: Initializing First Master Node ($FIRST_MASTER)"
log_info "====================================================="

# Skip if already initialized (idempotency)
if is_step_completed "$FIRST_MASTER" "master_init"; then
  log_warn "First master node $FIRST_MASTER already initialized - skipping initialization"
else
  # Clean up previous cluster state (safe reset)
  log_info "Resetting first master node to clean state..."
  ssh $SSH_COMMON_OPTS "$FIRST_MASTER" "sudo kubeadm reset -f > /dev/null 2>&1 || true"

  # Execute kubeadm init with explicit configuration
  log_info "Executing kubeadm init on $FIRST_MASTER..."
  ssh $SSH_COMMON_OPTS "$FIRST_MASTER" << EOF
    set -euo pipefail
    sudo kubeadm init \
      --control-plane-endpoint "$CP_ENDPOINT" \
      --upload-certs \
      --kubernetes-version=$K8S_VERSION \
      --pod-network-cidr=$POD_CIDR \
      --ignore-preflight-errors=SystemVerification

    # Configure kubectl for default user (non-root)
    mkdir -p \$HOME/.kube
    sudo cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config
    sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config
EOF

  # Mark initialization as completed
  mark_step_completed "$FIRST_MASTER" "master_init"
  log_info "Successfully initialized first master node: $FIRST_MASTER"
fi

# =============================================================================
# Extract Cluster Join Credentials
# =============================================================================
log_info "Extracting cluster join credentials from first master..."
# Get join command (token-based)
JOIN_CMD=$(ssh $SSH_COMMON_OPTS "$FIRST_MASTER" "kubeadm token create --print-join-command" | tr -d '\r')
# Get certificate key for additional master nodes
CERT_KEY=$(ssh $SSH_COMMON_OPTS "$FIRST_MASTER" "sudo kubeadm init phase upload-certs --upload-certs | tail -1" | tr -d '\r')

# Validate extracted credentials
[ -z "$JOIN_CMD" ] && log_error "Failed to extract join command from first master node: $FIRST_MASTER"
[ -z "$CERT_KEY" ] && log_error "Failed to extract certificate key from first master node: $FIRST_MASTER"

# =============================================================================
# Join Additional Master Nodes to Cluster
# =============================================================================
log_info "====================================================="
log_info "PHASE 2: Joining Additional Master Nodes"
log_info "====================================================="


for i in "${!MASTERS[@]}"; do
  # Skip first master (already initialized)
  if [ $i -ne 0 ]; then
    NODE="${MASTERS[$i]}"

    # Skip if already joined (idempotency)
    if is_step_completed "$NODE" "master_join"; then
      log_warn "Master node $NODE already joined - skipping"
      continue
    fi

    log_info "Processing additional master node: $NODE"
    # Reset node to clean state before join
    ssh $SSH_COMMON_OPTS "$NODE" "sudo kubeadm reset -f > /dev/null 2>&1 || true"
    # Join node to control plane
    ssh $SSH_COMMON_OPTS "$NODE" "sudo $JOIN_CMD --control-plane --certificate-key $CERT_KEY"
    # Mark step as completed
    mark_step_completed "$NODE" "master_join"
    log_info "Successfully joined master node to cluster: $NODE"
  fi
done

# =============================================================================
# Join Worker Nodes to Cluster
# =============================================================================
log_info "====================================================="
log_info "PHASE 3: Joining Worker Nodes"
log_info "====================================================="

for NODE in "${WORKERS[@]}"; do
  # Skip if already joined (idempotency)
  if is_step_completed "$NODE" "worker_join"; then
    log_warn "Worker node $NODE already joined - skipping"
    continue
  fi

  log_info "Processing worker node: $NODE"
  # Reset node to clean state before join
  ssh $SSH_COMMON_OPTS "$NODE" "sudo kubeadm reset -f > /dev/null 2>&1 || true"
  # Join worker node to cluster
  ssh $SSH_COMMON_OPTS "$NODE" "sudo $JOIN_CMD"
  # Mark step as completed
  mark_step_completed "$NODE" "worker_join"
  log_info "Successfully joined worker node to cluster: $NODE"
done

# =============================================================================
# Deploy Flannel CNI and Configure Jump Server
# =============================================================================
log_info "====================================================="
log_info "PHASE 4: Deploying Flannel CNI and Configuring Jump Server"
log_info "====================================================="

# Deploy Flannel CNI with validation and retries
log_info "Verifying Flannel CNI deployment status..."
if ! check_flannel_status "$FIRST_MASTER"; then
  log_info "Deploying Flannel CNI network (3 retries on failure)..."

  # Retry Flannel deployment up to 3 times
  for attempt in {1..3}; do
    if ssh $SSH_COMMON_OPTS "$FIRST_MASTER" "kubectl apply -f $FLANNEL_YAML"; then
      log_info "Flannel CNI applied successfully (attempt $attempt)"
      break
    else
      log_warn "Flannel CNI deployment failed (attempt $attempt) - retrying in 10 seconds"
      sleep 10
      # Fail fatally after 3 attempts
      if [ $attempt -eq 3 ]; then
        log_error "Failed to deploy Flannel CNI after 3 attempts - check network connectivity"
      fi
    fi
  done

  # Wait for Flannel pods to reach ready state (5 minute timeout)
  log_info "Waiting for Flannel pods to become ready (timeout: 5 minutes)..."
  if ! ssh $SSH_COMMON_OPTS "$FIRST_MASTER" "kubectl wait --for=condition=ready pod -n kube-flannel -l app=flannel --timeout=5m"; then
    log_error "Flannel pods failed to reach ready state within timeout period"
  fi

  # Final validation of Flannel deployment
  if ! check_flannel_status "$FIRST_MASTER"; then
    log_error "Flannel CNI deployment validation failed - pods not running"
  fi
else
  log_info "Flannel CNI already deployed and running - skipping deployment"
fi

# Configure kubectl on jump server (local machine)
log_info "Configuring kubectl on jump server (local machine)..."
mkdir -p "$HOME/.kube"
# Copy admin config from first master to jump server
ssh $SSH_COMMON_OPTS "$FIRST_MASTER" "sudo cat /etc/kubernetes/admin.conf" > "$HOME/.kube/config"
# Secure kubeconfig file (restrict permissions)
chmod 600 "$HOME/.kube/config"

# Verify final cluster status
log_info "Verifying final cluster node status..."
ssh $SSH_COMMON_OPTS "$FIRST_MASTER" "kubectl get nodes -o wide"

# =============================================================================
# Final Completion Notification
# =============================================================================
log_info "====================================================="
log_info "KUBERNETES CLUSTER INITIALIZATION COMPLETED SUCCESSFULLY!"
log_info "====================================================="
log_info "Cluster configuration file: $HOME/.kube/config"
log_info "Verify cluster status with: kubectl get nodes"
log_info "Verify CNI status with: kubectl get pods -n kube-flannel"