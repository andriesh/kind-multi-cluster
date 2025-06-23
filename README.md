# Multi-KIND Cluster Manager

![Multi-KIND Cluster Manager](./docs/images/kind-clusters.png)

A bash utility for creating and managing multiple Kubernetes KIND (Kubernetes IN Docker) clusters with separate IP addresses for local development and testing.

## 🚀 Features

- **Multiple Clusters**: Create and manage multiple KIND clusters on a single machine
- **IP Aliasing**: Assign dedicated IP addresses to each cluster for realistic multi-cluster setups
- **MetalLB Integration**: Automatic setup of MetalLB for LoadBalancer services
- **Manifest Management**: Apply Kubernetes manifests to your clusters automatically
- **Easy Management**: Simple commands to create, delete, and check cluster status

## 📋 Prerequisites

- Docker
- [KIND](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- kubectl
- Linux environment with root/sudo privileges (for network configuration)

## 📥 Installation

1. Clone this repository:
   ```bash
   git clone https://github.com/yourusername/multi-kind-cluster-manager.git
   cd multi-kind-cluster-manager
   ```

2. Make the script executable:
   ```bash
   chmod +x multi-cluster-setup.sh
   ```

## 🔧 Usage

### Initialize a New Cluster Configuration

```bash
./multi-cluster-setup.sh init cluster1 192.168.55.51
```

This creates a template configuration in `clusters/cluster1/` with:
- Network configuration (`config/cluster.env`)
- KIND cluster configuration (`config/kind-config.yaml`)
- MetalLB configuration (`config/metallb.yaml`)
- Sample application manifest (`manifests/test-app.yaml`)

### Create a Cluster

```bash
./multi-cluster-setup.sh create cluster1
```

This:
1. Sets up an alias IP address on your network interface
2. Creates a KIND cluster with the specified configuration
3. Installs MetalLB for LoadBalancer support
4. Applies manifests from the `manifests/` directory

### Check Cluster Status

```bash
# Check a specific cluster
./multi-cluster-setup.sh status cluster1

# Check all clusters
./multi-cluster-setup.sh status
```

### List All Cluster Configurations

```bash
./multi-cluster-setup.sh list
```

### Delete a Cluster

```bash
./multi-cluster-setup.sh delete cluster1
```

## ⚙️ Configuration Structure

```
clusters/
└── cluster1/
    ├── config/
    │   ├── cluster.env        # Network and environment configuration
    │   ├── kind-config.yaml   # KIND cluster configuration
    │   ├── kubeconfig         # Generated kubeconfig file
    │   └── metallb.yaml       # MetalLB configuration
    ├── manifests/             # Kubernetes manifests to apply
    │   └── test-app.yaml
    └── README.md              # Cluster-specific documentation
```

### Customizing Cluster Configuration

Edit `clusters/<name>/config/cluster.env` to customize:
- `CLUSTER_IP`: The dedicated IP for this cluster
- `SUBNET`: Network subnet
- `GATEWAY`: Network gateway
- `PARENT_INTERFACE`: Your host network interface (e.g., eth0, enp0s31f6)

Edit `clusters/<name>/config/kind-config.yaml` to customize:
- Number of worker nodes
- Port mappings
- Other KIND-specific settings

## 🔍 Troubleshooting

- **Error assigning IP address**: Ensure you have the correct network interface name in `PARENT_INTERFACE` and that you have root/sudo privileges
- **Cluster creation fails**: Check Docker is running and you have enough resources
- **MetalLB not working**: Verify your network configuration and that the IP addresses are correctly set

## 📄 License

This project is licensed under the MIT License - see the LICENSE file for details.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request
