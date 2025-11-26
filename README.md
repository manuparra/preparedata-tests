# 📘 PrepareData Benchmarks Suite

Benchmarks for Data Copy, Bind Mount Stress, and Kubernetes PV/PVC Provisioning
*(Designed to evaluate system impact and scaling behaviour in PrepareData-like workflows)*

---

## 📌 Overview

This repository contains three benchmark scripts designed to evaluate the performance characteristics of different mechanisms used in **PrepareData** workflows:

1. **Dataset Copy Benchmark** (`copy.sh`)
   → Measures raw filesystem I/O performance for sequential data copying.

2. **Bind Mount Stress Benchmark** (`mount.sh`)
   → Evaluates kernel-side overhead when performing large numbers of `mount --bind` operations.

3. **Kubernetes PV/PVC Provisioning Benchmark** (`pvpvc.sh`)
   → Tests the latency and CPU cost of creating large batches of PVCs, simulating PrepareData workspace provisioning.

Each benchmark produces machine-readable CSV output for further analysis, suitable for graphing or inclusion in scientific reports.

---

## 🧠 Context

PrepareData pipelines often involve:

* Moving large datasets between storage layers.
* Creating numerous mount points to expose user workspaces.
* Dynamically provisioning storage (PV/PVC) inside Kubernetes clusters.

These operations impose different types of loads:

| Operation Type  | Main Cost                   | Where It Impacts                    |
| --------------- | --------------------------- | ----------------------------------- |
| Copying data    | Raw disk I/O                | Worker node I/O subsystem           |
| `mount --bind`  | Kernel VFS operations       | Worker node CPU (system mode)       |
| PV/PVC creation | API calls + storage backend | Control-plane CPU, provisioner load |

---

# 🧪 1. Dataset Copy Benchmark

**File:** `copy.sh`

## 🎯 Aim

Measure **time and performance trends** when copying datasets of various sizes from a source directory to a destination directory.
Useful to estimate I/O bottlenecks and throughput during data staging phases.

---

## ▶️ How It Works

For each size in MB:

```
100, 200, 500, 1024, 2048, 3072, 4096, 5120
```

The script:

1. Generates a file of the given size using `dd`.
2. Copies it to the destination directory **five times**.
3. Measures:

   * High-precision elapsed time per copy.
   * Computes average copy time.
4. Removes generated files.

---

## ▶️ Usage

```bash
chmod +x copy.sh
./copy.sh /path/to/SOURCE /path/to/DESTINATION
```

---

## 📤 Output Format (CSV)

```
size_MB; avg_time_seconds
```

Example:

```
1024; 1.372
```

---

# 🧪 2. Bind Mount Stress Benchmark

**File:** `mount.sh`

## 🎯 Aim

Evaluate CPU/system overhead when performing **large numbers of `mount --bind` operations**.

`mount --bind` is extremely fast, so the goal is **not latency per mount**, but:

* System CPU consumed.
* Scaling behaviour with many mounts.
* Total wall-clock time.
* Stress on the worker node.

This simulates PrepareData cases where many directories are bound-mounted into user pods.

---

## ▶️ How It Works

For each scenario of:

```
10, 50, 100, 200, 400, 800 mounts
```

Each run:

1. Creates the required number of mount points.
2. Measures:

   * Wall-clock time
   * User CPU time
   * System CPU time (syscalls)
   * `sys_cpu_fraction = sysCPU / wallClock`
3. Unmounts and removes all mount points.
4. Repeats 5 times for statistical significance.

---

## ▶️ Usage

```bash
sudo chmod +x mount.sh
sudo ./mount.sh /source/dir /mnt/bind_test
```

> ⚠️ Must run as **root** for mount/umount.

---

## 📤 Output Format (CSV)

```
num_mounts; avg_total_time_seconds; avg_user_cpu_seconds; avg_sys_cpu_seconds; avg_sys_cpu_fraction
```

Example:

```
200; 0.188; 0.003; 0.089; 0.473
```

---

# 🧪 3. Kubernetes PV/PVC Provisioning Benchmark

**File:** `pvpvc.sh`

## 🎯 Aim

Evaluate how the Kubernetes control-plane and storage backend behave when creating large batches of PVCs.

This simulates PrepareData workloads where user pods need dynamic workspace creation backed by PV/PVC.

Specifically evaluates:

* Latency from creation → Bound state
* CPU cost of API calls (client-side)
* Impact of scaling PVC counts

---

## ▶️ How It Works

For each scenario of:

```
5, 10, 20, 50, 100 PVCs
```

Each run:

1. Creates N PVCs with a selected StorageClass.
2. Waits until **all** PVCs reach `Bound`.
3. Measures:

   * Wall-clock time
   * CPU user/sys time
   * Fraction of sys CPU versus wall time
4. Deletes all PVCs.
5. Repeats 5 times.

---

## ▶️ Usage

```bash
chmod +x pvpvc.sh
./pvpvc.sh <namespace> <storageClass> <size>
```

Example:

```bash
./pvpvc.sh pd-bench ceph-rbd 1Gi
```

---

## 📤 Output Format (CSV)

```
num_pvcs; avg_total_time_seconds; avg_user_cpu_seconds; avg_sys_cpu_seconds; avg_sys_cpu_fraction
```

Example:

```
20; 14.502; 0.076; 0.590; 0.041
```

---

# 📊 What To Do With the CSV Outputs

You can easily load the CSV files into:

* Python (pandas)
* R scripts
* Excel / Google Sheets
* Grafana dashboards
* Jupyter notebooks

Generate plots such as:

* Time vs number of PVCs
* System CPU fraction vs mounts
* Copy throughput (MB/s)
* Scaling curves comparing bind mounts vs PVCs

---

# 📁 Repository Structure

```
/
├── copy.sh
├── mount.sh
├── pvpvc.sh
└── README.md
```

---

# 🤝 Contributing

PRs welcome for:

* Additional storage backends
* Parallel stress models
* Pod-creation benchmarks
* Node-level telemetrics integration
