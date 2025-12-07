# 💾 vSphere Dynamic Load Balancer (PowerCLI)

An automated PowerShell script using VMware PowerCLI to dynamically balance the compute (CPU/RAM) and storage (Datastore) load across ESXi hosts within a vCenter environment.

## 🌟 Features

This script goes beyond simple CPU/RAM balancing by incorporating a multi-faceted approach to identify the true host bottleneck and select the most effective Virtual Machine (VM) for migration.

* **Triple-Metric Triggering:** Initiates load balancing if any of the following thresholds are exceeded:
    * **CPU Usage** (`CpuThreshold`)
    * **Memory Usage** (`MemThreshold`)
    * **Local Datastore Usage** (`DatastoreThresholdPct`)
* **Intelligent VM Selection:** The candidate VM for migration is selected based on the specific host bottleneck:
    * **If CPU is the bottleneck:** Selects the VM with the **highest active CPU load (MHz)**.
    * **If RAM is the bottleneck:** Selects the VM with the **largest amount of Configured RAM (MemoryGB)**, ensuring maximum capacity recovery.
    * **If Datastore is the bottleneck:** Selects the VM consuming the **largest amount of Used Disk Space (UsedSpaceGB)** on the overloaded local datastore.
* **Safety and Admission Control:** Ensures concurrent migrations are prevented via a task lock, and verifies the target host has sufficient resources (CPU, RAM, and Disk Space) *before* initiating vMotion.
* **Exclusion Lists:** Allows excluding specific hosts or critical VMs from being moved.

---

## 🛠 Prerequisites

1.  **VMware PowerCLI:** Must be installed on the machine running the script.
2.  **vCenter Access:** Credentials with permissions to connect to vCenter, read host/VM statistics, and execute `Move-VM` operations.
3.  **Log Directory:** The directory specified in `$LogDirectory` must exist or the script must have permissions to create it.

---

## 🚀 Setup and Installation

### 1. Download Files

Download the two files into the same directory on your execution machine:

* `LoadBalancer_Script.ps1` (The main logic)
* `LoadBalancer_Config.psd1` (The configuration file)

### 2. Configure `LoadBalancer_Config.psd1`

Open the `.psd1` file and adjust the parameters to match your environment and requirements.

| Parameter | Type | Description | Default Value |
| :--- | :--- | :--- | :--- |
| **`vCenterServer`** | String | The IP address or FQDN of your vCenter server. | `"10.10.10.10"` |
| **`Username`** | String | Administrator or service account username. | `"Administrator"` |
| **`Password`** | String | The password for the service account. | `"XXXXXXXXX"` |
| **`CpuThreshold`** | Integer | CPU usage percentage to trigger a host migration. | `80` |
| **`MemThreshold`** | Integer | Memory usage percentage to trigger a host migration. | `80` |
| **`DatastoreThresholdPct`** | Integer | **NEW:** Datastore usage percentage to trigger a migration (for local datastores only). | `85` |
| **`StatInterval`** | Integer | The statistics interval (in seconds) used by `Get-Stat`. E.g., `300` for 5-minute average. | `300` |
| **`LogDirectory`** | String | Path to store the daily log files. | `"D:\VMware_Logs\..."` |
| **`LocalDatastorePattern`** | Array | Regex patterns to match the names of local datastores. **Crucial for disk balancing.** | `@("local-storage")` |
| **`ExcludeHostNames`** | Array | List of ESXi hosts to completely ignore. | `@("esxi-host-maintenance")` |
| **`ExcludeVMNames`** | Array | List of critical VMs that should never be moved. | `@("DomainController")` |

### 3. Enable Migration (Optional but Recommended)

For safety, the actual migration command is commented out by default. When you are confident in the script's logic and testing, uncomment the following line in `LoadBalancer_Script.ps1`:

```powershell
# Uncomment the line below to enable actual migration
#Move-VM -VM $VMToMove -Destination $Target.HostObj -Datastore $TargetDatastore -RunAsync | Out-Null
````

-----

## 💻 Usage and Scheduling

The script is designed to be run non-interactively, making it ideal for scheduled tasks.

### Manual Execution

Run the script from a PowerShell window (or the PowerCLI console):

```powershell
.\LoadBalancer_Script.ps1
```

### Scheduling via Windows Task Scheduler

To run this script automatically (e.g., every 5 minutes):

#### Create a Wrapper Script (`Start_Balancer.cmd`):

```dos
PowerShell.exe -File "C:\Path\To\LoadBalancer_Script.ps1"
```

#### Set up Task Scheduler:

Configure a new task:

  * **Action:** Start a program.
  * **Program/script:** `C:\Path\To\Start_Balancer.cmd`
  * **Trigger:** Set your desired recurring schedule (e.g., repeating every 5 minutes).

-----

## 💡 How the VM is Selected (The Logic)

When a host is flagged as overloaded, the script determines the single most pressing bottleneck and sorts the VMs accordingly to ensure the migration provides maximum relief:

| Bottleneck | Primary Sorting Criteria (Highest First) | Secondary Criteria | Goal |
| :--- | :--- | :--- | :--- |
| **CPU Load** (e.g., \> 80%) | **CPU Load (Mhz)** | Memory Usage (KB) | Reduce active compute load. |
| **RAM Overload** (e.g., \> 80%) | **Configured RAM (MemoryGB)** | Measured RAM Usage (KB) | Free up the largest potential capacity. |
| **Datastore Full** (e.g., \> 85%) | **Used Disk Space (GB)** | Configured RAM (GB) | Free up the largest disk space. |

### Note on RAM Measurement

Due to the unreliability of **`mem.usage.average`** reported by PowerCLI (often near zero), the script explicitly prioritizes the **Configured RAM (`MemoryGB`)** when the host's RAM threshold is exceeded. This is the correct operational approach to maximize host capacity recovery.
