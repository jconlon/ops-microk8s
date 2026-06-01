# Cluster Node Hardware Reference

8-node MicroK8s cluster. Last verified: 2026-05-31 via `dmidecode` on each node.

---

## Summary Table

| Node | IP | Role | Machine | CPU | RAM | Storage | GPU |
|---|---|---|---|---|---|---|---|
| mullet | 192.168.0.101 | Control plane | Dell OptiPlex 9010 | Core i7-3770, 4C/8T, 3.4 GHz | 32 GB | ~120 GB SSD | — |
| trout | 192.168.0.102 | Control plane | Dell OptiPlex 9010 | Core i7-3770, 4C/8T, 3.4 GHz | 32 GB | ~120 GB SSD | — |
| whale | 192.168.0.107 | Control plane + GPU | Dell Precision 3680 Tower | Core i7-14700, 20C/28T, 5.2 GHz boost | 32 GB | ~143 GB SSD | RTX 2000 Ada 16 GB |
| tuna | 192.168.0.103 | Worker | Dell OptiPlex 7020 | Core i5-4590, 4C/4T, 3.3 GHz | 16 GB | ~100 GB SSD | — |
| gold | 192.168.0.129 | Ceph storage worker | Dell PowerEdge R320 | Xeon E5-2407, 4C/4T, 2.2 GHz | 64 GB | ~100 GB SSD + 4 TB HDD | — |
| squid | 192.168.0.133 | Ceph storage worker | Dell PowerEdge R320 | Xeon E5-2407, 4C/4T, 2.2 GHz | 64 GB | ~100 GB SSD + 4 TB HDD | — |
| puffer | 192.168.0.135 | Ceph storage worker | Dell PowerEdge R320 | Xeon E5-2407, 4C/4T, 2.2 GHz | 64 GB | ~100 GB SSD + 4 TB HDD | — |
| carp | 192.168.0.137 | Ceph storage worker | Dell PowerEdge R320 | Xeon E5-2407, 4C/4T, 2.2 GHz | 64 GB | ~100 GB SSD + 4 TB HDD | — |

---

## Control Plane Nodes

### mullet

| Field | Value |
|---|---|
| IP | 192.168.0.101 |
| Role | Control plane (etcd master) |
| Machine | Dell OptiPlex 9010 |
| CPU | Intel Core i7-3770 (Ivy Bridge, Family 6 Model 58), 4C/8T, 3.4 GHz base |
| RAM | 32 GB |
| Boot storage | ~120 GB SSD |
| OS | Ubuntu 24.04.4 LTS |
| Kernel | 6.8.0-111-generic |
| MicroK8s | v1.32.13 |
| Notes | Runs Caddy reverse proxy for all verticon.com services |

---

### trout

| Field | Value |
|---|---|
| IP | 192.168.0.102 |
| Role | Control plane (etcd master) |
| Machine | Dell OptiPlex 9010 |
| CPU | Intel Core i7-3770 (Ivy Bridge, Family 6 Model 58), 4C/8T, 3.4 GHz base |
| RAM | 32 GB |
| Boot storage | ~120 GB SSD |
| OS | Ubuntu 24.04.3 LTS |
| Kernel | 6.8.0-106-generic |
| MicroK8s | v1.32.13 |
| Notes | Hosts primary PostgreSQL instance (production-postgresql-3) |

---

### whale

| Field | Value |
|---|---|
| IP | 192.168.0.107 |
| Role | Control plane + GPU inference node |
| Machine | Dell Precision 3680 Tower |
| CPU | Intel Core i7-14700 (Raptor Lake, Family 6 Model 183), 8P+12E = 20C/28T, 5.247 GHz boost |
| RAM | 32 GB |
| Boot storage | ~143 GB SSD |
| OS | Ubuntu 22.04.5 LTS |
| Kernel | 6.8.0-111-generic |
| MicroK8s | v1.32.13 |
| GPU | NVIDIA RTX 2000 Ada Generation |
| GPU VRAM | 16 GB GDDR6 |
| GPU architecture | Ada Lovelace, compute capability 8.9 |
| CUDA driver | 580.142 |
| CUDA runtime | 13.0 |
| PSU wattage | Unknown — DMI reports no value; requires physical inspection (see issue #71) |
| Notes | Only GPU node in cluster; runs vLLM for LLM inference |

**PCIe slots (from issue #71):**

| Slot | Type | Length | Status |
|---|---|---|---|
| SLOT2 | x16 PCIe | Full-length | In use (RTX 2000 Ada) |
| SLOT1 | x4 PCIe | Half-length | Available — too small for full-size GPU |
| SLOT4 | x4 PCIe | Half-length | Available — too small for full-size GPU |

---

## Worker Nodes

### tuna

| Field | Value |
|---|---|
| IP | 192.168.0.103 |
| Role | Worker |
| Machine | Dell OptiPlex 7020 |
| CPU | Intel Core i5-4590 (Haswell, Family 6 Model 60), 4C/4T, 3.3 GHz base |
| RAM | 16 GB |
| Boot storage | ~100 GB SSD |
| OS | Ubuntu 24.04.3 LTS |
| Kernel | 6.8.0-106-generic |
| MicroK8s | v1.32.13 |
| Notes | Smallest node in cluster; intermittent DNS/RBD issues (issues #39, #95) |

---

## Ceph Storage Nodes (Dell PowerEdge R320)

All four nodes are identical hardware. Each contributes one 4 TB Ceph OSD (16 TB raw total, ~5.3 TB usable at 3× replication).

| Field | Value |
|---|---|
| Machine | Dell PowerEdge R320 (1U rackmount) |
| CPU | Intel Xeon E5-2407 (Sandy Bridge-EP, Family 6 Model 45), 4C/4T, 2.2 GHz, no HT, no Turbo, AES-NI |
| RAM | 64 GB |
| Boot storage | ~100 GB SSD |
| Ceph OSD | 4 TB HDD |
| OS | Ubuntu 24.04 LTS |
| MicroK8s | v1.32.13 |
| iDRAC | Present on each node; sends UDP syslog → Loki via Promtail |

**Per-node:**

| Node | IP | Kernel | Notes |
|---|---|---|---|
| gold | 192.168.0.129 | 6.8.0-106-generic | |
| squid | 192.168.0.133 | 6.8.0-117-generic | |
| puffer | 192.168.0.135 | 6.8.0-117-generic | ACPI power key issue mitigated (issue #59) |
| carp | 192.168.0.137 | 6.8.0-117-generic | |

---

## Open Items

- [ ] **whale PSU wattage** — DMI returns Unknown; confirm by physical inspection before GPU upgrade (issue #71)
