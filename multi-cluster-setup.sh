#!/bin/bash

# Multi-KIND Cluster Setup with alias Networks
# Reads configuration from clusters/<cluster_name>/config/
# Applies manifests from clusters/<cluster_name>/manifests/

set -e

CONFIG_BASE_DIR="./clusters"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Check prerequisites
check_prerequisites() {
    if ! command -v docker &> /dev/null; then
        error "Docker is not installed"
        exit 1
    fi
    
    if ! command -v kind &> /dev/null; then
        error "KIND is not installed"
        exit 1
    fi
    
    if ! command -v kubectl &> /dev/null; then
        warn "kubectl is not installed"
    fi
}

# Load cluster configuration
load_cluster_config() {
    local cluster_name=$1
    local cluster_dir="$CONFIG_BASE_DIR/$cluster_name"
    local config_file="$cluster_dir/config/cluster.env"
    
    if [[ ! -d "$cluster_dir" ]]; then
        error "Cluster directory not found: $cluster_dir"
        exit 1
    fi
    
    if [[ ! -f "$config_file" ]]; then
        error "Cluster config not found: $config_file"
        exit 1
    fi
    
    # Source the configuration
    source "$config_file"
    
    # Validate required variables
    if [[ -z "$CLUSTER_IP" || -z "$SUBNET" || -z "$GATEWAY" || -z "$PARENT_INTERFACE" ]]; then
        error "Missing required configuration in $config_file"
        error "Required: CLUSTER_IP, SUBNET, GATEWAY, PARENT_INTERFACE"
        exit 1
    fi
    
    log "Loaded config for $cluster_name: IP=$CLUSTER_IP"
}

# Create alias network
create_alias_network() {
    local cluster_name=$1
    
    log "Assigning additional IP: $CLUSTER_IP to network $PARENT_INTERFACE"
    
    # Check if interface exists
    if ! ip link show "$PARENT_INTERFACE" &> /dev/null; then
        error "Network interface $PARENT_INTERFACE does not exist"
        exit 1
    fi
    
    # Assign additional IP to parent interface
    ip addr add "$CLUSTER_IP/32" dev "$PARENT_INTERFACE" || {
        warn "Failed to assign IP $CLUSTER_IP to interface $PARENT_INTERFACE"
    }
    
    log "Assigned IP: $CLUSTER_IP"
}

# Create KIND cluster
create_kind_cluster() {
    local cluster_name=$1
    local cluster_dir="$CONFIG_BASE_DIR/$cluster_name"
    local kind_config="$cluster_dir/config/kind-config.yaml"
    
    if [[ ! -f "$kind_config" ]]; then
        error "KIND config not found: $kind_config"
        exit 1
    fi
    
    log "Creating KIND cluster: $cluster_name"
    log "Using config: $kind_config"
    
    # Create KIND cluster
    kind create cluster --config "$kind_config"
    
    # Save kubeconfig
    mkdir -p "$cluster_dir/config"
    kind get kubeconfig --name "$cluster_name" > "$cluster_dir/config/kubeconfig"
    
    log "Cluster $cluster_name created successfully"
}

# Apply Mettalb manifests
apply_metallb() {
    local cluster_name=$1
    local cluster_dir="$CONFIG_BASE_DIR/$cluster_name"
    local metallb_manifest="$cluster_dir/config/metallb.yaml"
    kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.13.7/config/manifests/metallb-native.yaml
    echo "Waiting for MetalLB to complete..."
    kubectl wait pod --all --for condition=Ready --namespace metallb-system --timeout 10m
    sleep 5
    kubectl apply -f $metallb_manifest || sleep 15 && kubectl apply -f $metallb_manifest
    log "MetalLB applied to cluster $cluster_name"
}

# Apply Kubernetes manifests
apply_manifests() {
    local cluster_name=$1
    local cluster_dir="$CONFIG_BASE_DIR/$cluster_name"
    local manifests_dir="$cluster_dir/manifests"
    
    if [[ ! -d "$manifests_dir" ]]; then
        log "No manifests directory found, skipping manifest application"
        return 0
    fi
    
    log "Applying manifests from: $manifests_dir"
    
    # Apply all YAML files in manifests directory
    for manifest in "$manifests_dir"/*.yaml "$manifests_dir"/*.yml; do
        if [[ -f "$manifest" ]]; then
            log "Applying: $(basename "$manifest")"
            kubectl --context "kind-$cluster_name" apply -f "$manifest"
        fi
    done
    
    log "All manifests applied"
}

# Create cluster
create_cluster() {
    local cluster_name=$1
    
    if [[ -z "$cluster_name" ]]; then
        error "Cluster name is required"
        exit 1
    fi
    
    log "Creating cluster: $cluster_name"
    
    check_prerequisites
    
    # Load cluster configuration
    load_cluster_config "$cluster_name"
    
    # Check if cluster already exists
    if kind get clusters | grep -q "^$cluster_name$"; then
        warn "Cluster $cluster_name already exists!"
        read -p "Recreate it? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            log "Deleting existing cluster..."
            kind delete cluster --name "$cluster_name" || true
        else
            log "Keeping existing cluster"
            return 0
        fi
    fi
    
    # Create alias network
    create_alias_network "$cluster_name"
    
    # Create KIND cluster
    create_kind_cluster "$cluster_name"

    # Apply Metallb manifests
    apply_metallb "$cluster_name"
    
    # Apply manifests
    apply_manifests "$cluster_name"
    
    log "Cluster $cluster_name setup complete!"
    
    # Show cluster info
    display_cluster_info "$cluster_name"
}

# Delete cluster
delete_cluster() {
    local cluster_name=$1

    # Load cluster configuration
    load_cluster_config "$cluster_name"
    
    if [[ -z "$cluster_name" ]]; then
        error "Cluster name is required"
        exit 1
    fi
    
    log "Deleting cluster: $cluster_name"
    
    # Delete KIND cluster
    kind delete cluster --name "$cluster_name" || true
    
    log "Cluster $cluster_name deleted"

    # Remove assigned IP from parent interface
    log "Removing IP $CLUSTER_IP from interface $PARENT_INTERFACE"
    ip addr del "$CLUSTER_IP/32" dev "$PARENT_INTERFACE" || {
        warn "Failed to remove IP $CLUSTER_IP from interface $PARENT_INTERFACE"
    }
    
}

# Show cluster status
show_cluster_status() {
    local cluster_name=$1
    
    if [[ -n "$cluster_name" ]]; then
        show_single_cluster_status "$cluster_name"
    else
        show_all_clusters_status
    fi
}

# Show single cluster status
show_single_cluster_status() {
    local cluster_name=$1
    local cluster_dir="$CONFIG_BASE_DIR/$cluster_name"
    
    echo ""
    echo "=== $cluster_name ==="
    
    # Check if config exists
    if [[ ! -d "$cluster_dir" ]]; then
        echo "✗ Configuration directory missing: $cluster_dir"
        return
    fi
    
    # Load config
    if load_cluster_config "$cluster_name" 2>/dev/null; then
        echo "✓ Configuration loaded (IP: $CLUSTER_IP)"
    else
        echo "✗ Failed to load configuration"
        return
    fi
    
    # Check if cluster exists
    if kind get clusters | grep -q "^$cluster_name$"; then
        echo "✓ KIND cluster exists"
        if kubectl --context "kind-$cluster_name" get nodes &>/dev/null; then
            echo "✓ Cluster is accessible"
            local node_count=$(kubectl --context "kind-$cluster_name" get nodes --no-headers | wc -l)
            echo "  📊 Nodes: $node_count"
        else
            echo "✗ Cluster not accessible"
        fi
    else
        echo "✗ KIND cluster does not exist"
    fi
    
    # Check manifests
    local manifests_dir="$cluster_dir/manifests"
    if [[ -d "$manifests_dir" ]]; then
        local manifest_count=$(find "$manifests_dir" -name "*.yaml" -o -name "*.yml" 2>/dev/null | wc -l)
        echo "✓ Manifests directory exists ($manifest_count files)"
    else
        echo "- No manifests directory"
    fi
}

# Show all clusters status
show_all_clusters_status() {
    log "Scanning for cluster configurations..."
    
    if [[ ! -d "$CONFIG_BASE_DIR" ]]; then
        warn "Configuration directory not found: $CONFIG_BASE_DIR"
        return
    fi
    
    local found_clusters=false
    for cluster_dir in "$CONFIG_BASE_DIR"/*; do
        if [[ -d "$cluster_dir" ]]; then
            local cluster_name=$(basename "$cluster_dir")
            show_single_cluster_status "$cluster_name"
            found_clusters=true
        fi
    done
    
    if [[ "$found_clusters" == "false" ]]; then
        warn "No cluster configurations found in $CONFIG_BASE_DIR"
    fi
}

# Display cluster information
display_cluster_info() {
    local cluster_name=$1
    local cluster_dir="$CONFIG_BASE_DIR/$cluster_name"
    
    echo ""
    info "=== CLUSTER: $cluster_name ==="
    echo "" 
    info "🌐 Cluster IP: $CLUSTER_IP"
    info "📁 Config Directory: $cluster_dir"
    info "🔧 Kubectl Context: kind-$cluster_name"
    echo ""
    info "Quick Commands:"
    echo "  kubectl --context kind-$cluster_name get nodes"
    echo "  kubectl --context kind-$cluster_name get pods -A"
    echo "  export KUBECONFIG=$SCRIPT_DIR/$cluster_dir/config/kubeconfig"
    echo ""
    info "Access cluster:"
    echo "  🌐 Direct IP: http://$CLUSTER_IP"
    echo "  🔗 Port forward: kubectl --context kind-$cluster_name port-forward svc/<service> 8080:80"
    echo ""
}

# List available cluster configurations
list_clusters() {
    echo "Available cluster configurations:"
    
    if [[ ! -d "$CONFIG_BASE_DIR" ]]; then
        warn "Configuration directory not found: $CONFIG_BASE_DIR"
        return
    fi
    
    local found_clusters=false
    for cluster_dir in "$CONFIG_BASE_DIR"/*; do
        if [[ -d "$cluster_dir" ]]; then
            local cluster_name=$(basename "$cluster_dir")
            local status="❌"
            local ip="unknown"
            
            # Try to load config and check status
            if load_cluster_config "$cluster_name" 2>/dev/null; then
                ip="$CLUSTER_IP"
                if kind get clusters | grep -q "^$cluster_name$"; then
                    status="✅"
                fi
            fi
            
            echo "  $status $cluster_name ($ip)"
            found_clusters=true
        fi
    done
    
    if [[ "$found_clusters" == "false" ]]; then
        warn "No cluster configurations found in $CONFIG_BASE_DIR"
        echo ""
        info "Create a cluster configuration:"
        echo "  mkdir -p clusters/cluster1/config"
        echo "  # Add cluster.env and kind-config.yaml"
        echo "  $0 create cluster1"
    fi
}

# Initialize cluster template
init_cluster() {
    local cluster_name=$1
    local cluster_ip=$2
    
    if [[ -z "$cluster_name" ]]; then
        error "Cluster name is required"
        echo "Usage: $0 init <cluster_name> <cluster_ip>"
        exit 1
    fi
    
    if [[ -z "$cluster_ip" ]]; then
        error "Cluster IP is required"
        echo "Usage: $0 init <cluster_name> <cluster_ip>"
        exit 1
    fi
    
    local cluster_dir="$CONFIG_BASE_DIR/$cluster_name"
    
    if [[ -d "$cluster_dir" ]]; then
        warn "Cluster configuration already exists: $cluster_dir"
        read -p "Overwrite? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "Keeping existing configuration"
            return 0
        fi
    fi
    
    log "Initializing cluster configuration: $cluster_name"
    # Create directory structure
    mkdir -p "$cluster_dir"/{config,manifests}
    # Create cluster.env
    cat > "$cluster_dir/config/cluster.env" << EOF
# Cluster Configuration for $cluster_name
CLUSTER_IP="$cluster_ip"
SUBNET="192.168.55.0/24"      # Change to your subnet
GATEWAY="192.168.55.1"        # Change to your gateway IP
PARENT_INTERFACE="enp0s31f6"  # Change to your parent interface
EOF
    
    # Create kind-config.yaml
    cat > "$cluster_dir/config/kind-config.yaml" << EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: $cluster_name
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
    listenAddress: "$cluster_ip"
  - containerPort: 443
    hostPort: 443
    protocol: TCP
    listenAddress: "$cluster_ip"
- role: worker
- role: worker
EOF
    
    # Create Metallb manifest
    cat> "$cluster_dir/config/metallb.yaml" << EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default
  namespace: metallb-system
spec:
  addresses:
  - $cluster_ip-$cluster_ip
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: empty
  namespace: metallb-system
EOF

    # Create sample manifest
    cat > "$cluster_dir/manifests/test-app.yaml" << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-app
  template:
    metadata:
      labels:
        app: test-app
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: test-app
  namespace: default
spec:
  selector:
    app: test-app
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF
    
    # Create README
    cat > "$cluster_dir/README.md" << EOF
# Cluster: $cluster_name

## Configuration
- **IP Address**: $cluster_ip
- **Network**: kind-net-$cluster_name

## Files
- \`config/cluster.env\` - Environment variables
- \`config/kind-config.yaml\` - KIND cluster configuration
- \`manifests/\` - Kubernetes manifests to apply

## Usage
\`\`\`bash
# Create cluster
$0 create $cluster_name

# Check status
$0 status $cluster_name

# Delete cluster
$0 delete $cluster_name
\`\`\`
EOF
    
    log "Cluster configuration created: $cluster_dir"
    log "Edit config/cluster.env and config/kind-config.yaml as needed"
    log "Add additional manifests to manifests/ directory"
    log "Then run: $0 create $cluster_name"
}

# Script usage
usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  init <name> <ip>        - Initialize cluster configuration"
    echo "  create <name>           - Create cluster from configuration"
    echo "  delete <name>           - Delete cluster"
    echo "  status [name]           - Show cluster status"
    echo "  list                    - List all cluster configurations"
    echo ""
    echo "Examples:"
    echo "  $0 init cluster1 192.168.55.51     - Initialize cluster1 config"
    echo "  $0 create cluster1                 - Create cluster1"
    echo "  $0 status cluster1                 - Show cluster1 status"
    echo "  $0 list                            - List all clusters"
    echo ""
    echo "Configuration structure:"
    echo "  clusters/<name>/config/cluster.env      - Environment config"
    echo "  clusters/<name>/config/kind-config.yaml - KIND configuration"
    echo "  clusters/<name>/manifests/*.yaml        - Kubernetes manifests"
}

# Main script logic
case "${1:-help}" in
    init)
        init_cluster "$2" "$3"
        ;;
    create)
        create_cluster "$2"
        ;;
    delete)
        delete_cluster "$2"
        ;;
    status)
        show_cluster_status "$2"
        ;;
    list)
        list_clusters
        ;;
    help|--help|-h)
        usage
        ;;
    *)
        error "Unknown command: ${1:-help}"
        usage
        exit 1
        ;;
esac