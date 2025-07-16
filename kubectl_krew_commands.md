## kubectl krew Commands

### Context and Namespace Management
- `kubectl ctx` - Switch between Kubernetes contexts quickly
- `kubectl ns` - Switch between Kubernetes namespaces quickly

### Cluster Health and Diagnostics
- `kubectl doctor` - Scan cluster for potential issues and misconfigurations
- `kubectl popeye` - Scan cluster for potential problems and resource optimization opportunities
- `kubectl janitor` - Clean up unused resources in the cluster

### Resource Discovery and Inspection
- `kubectl tree` - Display resources in a tree format showing parent-child relationships
- `kubectl service-tree` - Display services and their associated resources in a tree format
- `kubectl pod-inspect` - Detailed inspection of pod specifications and status
- `kubectl images` - List and analyze container images used across the cluster
- `kubectl neat` - Clean up kubectl output by removing managed fields and other noise

### Logging and Troubleshooting
- `kubectl pod-logs` - Enhanced pod log viewing with advanced filtering options
- `kubectl netshoot` - Network troubleshooting toolkit for debugging connectivity issues

### Interactive Tools
- `kubectl ipick` - Interactive pod picker for selecting pods from a list

### Service-Specific Plugins
- `kubectl ingress-nginx` - Manage and troubleshoot NGINX Ingress Controller
- `kubectl mayastor` - Manage Mayastor storage system resources
- `kubectl minio` - Manage MinIO object storage deployments

### Plugin Management
- `kubectl krew` - Install, update, and manage kubectl plugins
- `kubectl example` - Example plugin demonstrating krew plugin development