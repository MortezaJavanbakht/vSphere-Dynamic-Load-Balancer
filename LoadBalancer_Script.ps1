#
# LoadBalancer_Script.ps1 - Auto Load Balancer for vSphere
#

# **Step 1: Load Configuration and PowerCLI Setup**

# Find the current script path and the configuration file path
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ConfigFile = Join-Path -Path $ScriptDir -ChildPath "LoadBalancer_Config.psd1"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "CRITICAL: Configuration file '$ConfigFile' not found! Script cannot run." -ForegroundColor Red
    exit 1
}

# Load all settings from the psd1 file.
$Config = Import-PowerShellDataFile -Path $ConfigFile

# Map configuration settings to local variables for clarity
$vCenterServer = $Config.vCenterServer
$Username = $Config.Username
$Password = $Config.Password
$CpuThreshold = $Config.CpuThreshold
$MemThreshold = $Config.MemThreshold
$DatastoreThresholdPct = $Config.DatastoreThresholdPct 
$StatInterval = $Config.StatInterval
$LogDirectory = $Config.LogDirectory 
$LocalDatastorePattern = $Config.LocalDatastorePattern 
$ExcludeHostNames = $Config.ExcludeHostNames
$ExcludeVMNames = $Config.ExcludeVMNames


# **CRITICAL: Configure PowerCLI for non-interactive and secure operation**
# Ignore SSL certificate errors
Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false

# FIX: Set Default VIServer Mode to avoid the interactive prompt (Y/N)
Set-PowerCLIConfiguration -DefaultVIServerMode Single -Scope Session -Confirm:$false

# Log file name with daily date format
$LogFile = Join-Path -Path $LogDirectory -ChildPath "$(Get-Date -Format 'yyyy-MM-dd')_LoadBalancer.log"

# **Write-Log function for consistent logging and daily rotation**
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        [string]$Level = "INFO" # Can be INFO, WARNING, ERROR
    )

    # Format time and message
    $Timestamp = Get-Date -Format "HH:mm:ss"
    $LogEntry = "[$Timestamp] [$Level]: $Message"

    # Display on console
    Write-Host $LogEntry

    # Check for directory existence and create if necessary
    if (-not (Test-Path $LogDirectory)) {
        New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
    }

    # Append to the log file
    Add-Content -Path $LogFile -Value $LogEntry
}

# -------------------------------------------------------------------------------------

# Start the main script logic within a TRY block
try {
    # **Step 2: Connect to vCenter**
    Write-Log -Message "Starting Auto Load Balancer Script. Thresholds: CPU: $CpuThreshold%, RAM: $MemThreshold%, Datastore: $DatastoreThresholdPct%."

    if (-not $vCenterServer) {
        Write-Log -Message "CRITICAL: The \$vCenterServer variable is empty. Cannot connect." -Level "ERROR"
        return
    }

    try {
        Write-Log -Message "Connecting to vCenter $vCenterServer..."
        Connect-VIServer -Server $vCenterServer -User $Username -Password $Password -WarningAction SilentlyContinue | Out-Null
        Write-Log -Message "Connection successful."
    }
    catch {
        Write-Log -Message "Failed to connect to vCenter. Check credentials or network connectivity. $($_.Exception.Message)" -Level "ERROR"
        return
    }

    # **Step 3: Check for Existing Migration Tasks (Lock Mechanism)**
    $MigrationTasks = Get-Task | Where-Object { 
        $_.Name -like "*migrate*" -and ($_.State -eq "Running" -or $_.State -eq "Queued")
    }

    if ($MigrationTasks.Count -gt 0) {
        Write-Log -Message "Existing migration tasks found! Script will wait for the current migration to finish." -Level "WARNING"
        Write-Log -Message "Found $($MigrationTasks.Count) running or queued tasks. Example: $($MigrationTasks[0].Name)."
        return
    }
    Write-Log -Message "No active migration tasks detected. Proceeding with load analysis."


    # **Step 4: Analyze Host Resource Load Status and Max Datastore Capacity**
    $HostStats = @()
    $AllHosts = Get-VMHost | Where-Object { 
        # Filter for Connected hosts, not in Maintenance Mode
        $_.ConnectionState -eq "Connected" -and $_.GetType().Name -eq "VMHostImpl" -and $_.PowerState -ne "MaintenanceMode" -and 
        # Apply Host Exclusion Filter
        $_.Name -notin $ExcludeHostNames 
    }

    if ($ExcludeHostNames.Count -gt 0) {
        Write-Log -Message "Excluded hosts: $($ExcludeHostNames -join ', ')."
    }

    Write-Log -Message "Analyzing resource usage for $($AllHosts.Count) connected ESXi hosts."

    # Pre-compile the pattern list into a single regex for efficient filtering
    $CombinedDatastorePatternRegex = ($LocalDatastorePattern -join '|')

    foreach ($EsxHost in $AllHosts) {
        try {
            # Get CPU and Memory usage statistics (CPU and Mem usage in percentage)
            $CpuUsage = (Get-Stat -Entity $EsxHost -Stat cpu.usage.average -IntervalSec $StatInterval -MaxSamples 1).Value
            $MemUsage = (Get-Stat -Entity $EsxHost -Stat mem.usage.average -IntervalSec $StatInterval -MaxSamples 1).Value

            if (-not $CpuUsage -or -not $MemUsage) {
                Write-Log -Message "Get-Stat returned null/zero for critical metric on $($EsxHost.Name). Skipping this host." -Level "WARNING"
                continue
            }

            # Filter by Multiple Local Datastore Patterns
            $LocalDatastores = Get-Datastore -VMHost $EsxHost | Where-Object {$_.Name -match $CombinedDatastorePatternRegex}
            
            # --- Datastore Capacity Calculation ---
            $DatastoreUsagePct = 0
            $MaxFreeSpaceGB = 0
            
            if ($LocalDatastores.Count -gt 0) {
                # Find the Datastore with the most free space (this is the one used for admission check)
                $LargestDatastore = $LocalDatastores | Sort-Object -Property FreeSpaceGB -Descending | Select-Object -First 1
                
                $MaxFreeSpaceGB = [math]::Round($LargestDatastore.FreeSpaceGB, 2)
                $MaxTotalSpaceGB = [math]::Round($LargestDatastore.CapacityGB, 2)
                
                if ($MaxTotalSpaceGB -gt 0) {
                    $DatastoreUsagePct = [math]::Round((($MaxTotalSpaceGB - $MaxFreeSpaceGB) / $MaxTotalSpaceGB) * 100, 2)
                }
            } else {
                Write-Log -Message "Host $($EsxHost.Name): No Datastore found matching any pattern ('$($LocalDatastorePattern -join ', ')'). Skipping." -Level "WARNING"
                continue
            }
            # --------------------------------------

            # Compile Host Stats
            $HostStats += [PSCustomObject]@{
                Name = $EsxHost.Name
                HostObj = $EsxHost
                CpuPct = [math]::Round($CpuUsage, 2)
                MemPct = [math]::Round($MemUsage, 2)
                MaxFreeSpaceGB = $MaxFreeSpaceGB 
                DatastoreUsagePct = $DatastoreUsagePct 
                # Combined Load Index for better sorting (using % is fine for host sorting)
                LoadIndex = $CpuUsage + $MemUsage
                TotalRAM = [math]::Round($EsxHost.MemoryTotalGB, 2)
                UsedRAM = [math]::Round($EsxHost.MemoryUsageGB, 2)
                TotalMHz = $EsxHost.CpuTotalMhz
                UsedMHz = $EsxHost.CpuUsageMhz
            }
        }
        catch {
            Write-Log -Message "Error collecting stats for $($EsxHost.Name): $($_.Exception.Message)" -Level "ERROR"
        }
    }

    # Separate hosts into source (overloaded) and target (underloaded)
    # SourceHosts now includes Datastore-overloaded hosts
    $SourceHosts = $HostStats | Where-Object { 
        $_.CpuPct -ge $CpuThreshold -or 
        $_.MemPct -ge $MemThreshold -or 
        $_.DatastoreUsagePct -ge $DatastoreThresholdPct 
    } | Sort-Object -Property LoadIndex -Descending
    
    # Target Hosts only need to be below CPU/RAM thresholds
    $TargetHosts = $HostStats | Where-Object { $_.CpuPct -lt $CpuThreshold -and $_.MemPct -lt $MemThreshold } | Sort-Object -Property LoadIndex


    if ($SourceHosts.Count -eq 0) {
        Write-Log -Message "All hosts and datastores are within the defined resource thresholds. No migration needed."
        return
    }

    if ($TargetHosts.Count -eq 0) {
        Write-Log -Message "No suitable target host found with resources below the compute threshold. Cannot perform load balancing." -Level "WARNING"
        return
    }

    # **Step 5 & 6: Execute Migration Operations**
    Write-Log -Message "--- Starting Migration Process ---"

    foreach ($Source in $SourceHosts) {
        Write-Log -Message "Analyzing Source Host: $($Source.Name) (CPU: $($Source.CpuPct)%, RAM: $($Source.MemPct)%, DS: $($Source.DatastoreUsagePct)%)"

        # 1. Select the candidate VM for migration (VM with the heaviest load matching the host's bottleneck)
        
        # Determine the host's current bottleneck
        $IsCpuBottleneck = $Source.CpuPct -ge $CpuThreshold
        $IsMemBottleneck = $Source.MemPct -ge $MemThreshold
        $IsDatastoreBottleneck = $Source.DatastoreUsagePct -ge $DatastoreThresholdPct 

        # Define the initial sorting criteria based on the bottleneck (Dynamic Logic)
        if ($IsDatastoreBottleneck -and -not $IsCpuBottleneck -and -not $IsMemBottleneck) {
            # DATASTORE is the ONLY main problem: prioritize VMs by USED DISK SPACE
            $SortCriteria = @("UsedSpaceGB", "MemoryGB", "CpuLoadMhz")
            $SelectionMessage = "Host's largest Datastore is CAPACITY-overloaded. Prioritization by VM Disk Usage (UsedSpaceGB)."
        } elseif ($IsCpuBottleneck -and -not $IsMemBottleneck) {
            # CPU is the main problem: prioritize VMs by CPU load, then RAM usage
            $SortCriteria = @("CpuLoadMhz", "MemUsageKB")
            $SelectionMessage = "Host is CPU-overloaded. Prioritization by CPU Load (Mhz)."
        } elseif ($IsMemBottleneck -and -not $IsCpuBottleneck) {
            # RAM is the main problem: prioritize VMs by CONFIGURATION (MemoryGB), then Usage (MemUsageKB)
            $SortCriteria = @("MemoryGB", "MemUsageKB", "CpuLoadMhz") 
            $SelectionMessage = "Host is RAM-overloaded. Prioritization by Configured RAM (MemoryGB)."
        } else {
            # Multiple bottlenecks or default combined load: Default to CPU priority
            $SortCriteria = @("CpuLoadMhz", "MemoryGB", "UsedSpaceGB")
            $SelectionMessage = "Host has MULTIPLE bottlenecks. Prioritizing VM by CPU Load (Default)."
        }
        
        Write-Log -Message $SelectionMessage

        # Apply VM Exclusion Filter
        $CandidateVMs = Get-VM -Location $Source.HostObj | Where-Object {
            $_.PowerState -eq "PoweredOn" -and $_.Name -notin $ExcludeVMNames
        }
        
        if ($ExcludeVMNames.Count -gt 0) {
            Write-Log -Message "Excluded VMs: $($ExcludeVMNames -join ', ') (Filtered before stat collection)."
        }
        
        if ($CandidateVMs.Count -eq 0) {
            Write-Log -Message "No suitable powered-on VMs to move from $($Source.Name) after applying exclude filters."
            continue
        }

        # Collect CPU usage in MHz and standard Memory Usage (KB)
        $CandidateVMStats = $CandidateVMs | Get-Stat -Stat cpu.usagemhz.average, mem.usage.average -IntervalSec $StatInterval -MaxSamples 1 
        
        $VMsWithStats = $CandidateVMStats | Group-Object -Property Entity | ForEach-Object {
            $VM = $_.Group[0].Entity
            
            # Use CPU Usage in MHz
            $CpuUsageMhzStat = ($_.Group | Where-Object {$_.MetricId -like "*cpu.usagemhz.average*"}).Value
            
            # Use Memory Usage in KB
            $MemUsageKBStat = ($_.Group | Where-Object {$_.MetricId -like "*mem.usage.average*"}).Value
            
            [PSCustomObject]@{
                VMObj = $VM
                CpuLoadMhz = [math]::Round($CpuUsageMhzStat, 2)
                MemUsageKB = [math]::Round($MemUsageKBStat, 0)
                MemoryGB = [math]::Round($VM.MemoryGB, 2) 
                UsedSpaceGB = [math]::Round($VM.UsedSpaceGB, 2) 
            }
        } | Where-Object {$_.CpuLoadMhz -gt 0 -or $_.MemUsageKB -gt 0 -or $_.UsedSpaceGB -gt 0} 

        # Initial Sort
        $SortedVMs = $VMsWithStats | Sort-Object -Property $SortCriteria -Descending 
        $TopCandidate = $SortedVMs | Select-Object -First 1
        
        # --- SANITY CHECK (ONLY KEEPING CPU CHECK) ---
        if ($TopCandidate -ne $null) {
            # Sanity Check 1: If CPU is the ONLY problem, but candidate CPU load is near zero, re-sort by RAM Config/Usage
            # This check is kept because CpuLoadMhz is generally reliable.
            if ($IsCpuBottleneck -and -not $IsMemBottleneck -and -not $IsDatastoreBottleneck -and $TopCandidate.CpuLoadMhz -lt 10) { 
                 Write-Log -Message "Warning: Top CPU candidate ('$($TopCandidate.VMObj.Name)') has near-zero CPU usage. Re-sorting based on RAM Config/Usage." -Level "WARNING"
                 $SortCriteria = @("MemoryGB", "MemUsageKB", "CpuLoadMhz")
                 $SortedVMs = $VMsWithStats | Sort-Object -Property $SortCriteria -Descending 
                 $TopCandidate = $SortedVMs | Select-Object -First 1
            }
            # *** REMOVED SANITY CHECK FOR RAM BOTTLENECK: *** # When RAM is the bottleneck, we MUST trust MemoryGB and ignore unreliable MemUsageKB for selection.
        }


        $VMToMove = $TopCandidate.VMObj
        $VMCpuMhzEstimate = $TopCandidate.CpuLoadMhz
        $VMMemUsageKBEstimate = $TopCandidate.MemUsageKB

        if (-not $VMToMove) {
            Write-Log -Message "No suitable powered-on VMs with performance data to move from $($Source.Name)."
            continue
        }
        
        Write-Log -Message "Candidate VM selected: $($VMToMove.Name) (Config RAM: $($TopCandidate.MemoryGB) GB, CPU Load: $($VMCpuMhzEstimate) MHz, Used DS: $($TopCandidate.UsedSpaceGB) GB, Measured RAM: $([math]::Round($VMMemUsageKBEstimate/1MB, 2)) GB (RAW KB: $($VMMemUsageKBEstimate)))"

        # Get VM resource requirements (using configured memory for admission control check)
        $VMMemReqGB = [math]::Round($VMToMove.MemoryGB, 2)
        $VMDiskSpaceGB = [math]::Round($VMToMove.UsedSpaceGB, 2)

        # 2. Find the best target host that meets ALL resource requirements (Admission Control)
        $Target = $null
        foreach ($PotentialTarget in $TargetHosts) {
            # Check Disk Space
            if ($PotentialTarget.MaxFreeSpaceGB -lt $VMDiskSpaceGB) { continue }

            # Check RAM
            $FreeRAMGB = $PotentialTarget.TotalRAM - $PotentialTarget.UsedRAM
            if ($FreeRAMGB -lt $VMMemReqGB) { continue }
            
            # Strict CPU Check (Check post-migration usage estimate using the calculated Mhz)
            $NewUsedMHz = $PotentialTarget.UsedMHz + $VMCpuMhzEstimate
            $NewCpuPct = ($NewUsedMHz / $PotentialTarget.TotalMHz) * 100
            
            if ($NewCpuPct -ge $CpuThreshold) { continue }
            
            # Found the best target host
            $Target = $PotentialTarget
            break
        }

        if (-not $Target) {
            Write-Log -Message "Could not find any target host that meets all resource requirements for VM $($VMToMove.Name)." -Level "WARNING"
            continue
        }
        
        # 3. Execute Move-VM (Live Cross-Host Storage vMotion)
        Write-Log -Message "==> Moving VM '$($VMToMove.Name)' to target host '$($Target.Name)'."
        
        try {
            # Filter by Multiple Local Datastore Patterns
            $TargetLocalDatastores = Get-Datastore -VMHost $Target.HostObj | Where-Object {$_.Name -match $CombinedDatastorePatternRegex}
            
            # Select the single Datastore with the most free space to receive the VM
            $TargetDatastore = $TargetLocalDatastores | Sort-Object -Property FreeSpaceGB -Descending | Select-Object -First 1
            
            if (-not $TargetDatastore) {
                Write-Log -Message "Critical: Target host $($Target.Name) unexpectedly has no local datastore matching any pattern ('$($LocalDatastorePattern -join ', ')')." -Level "ERROR"
                continue
            }

            # Update Target Host Stats BEFORE migration is initiated 
            $Target.UsedRAM = $Target.UsedRAM + $VMMemReqGB
            $Target.UsedMHz = $Target.UsedMHz + $VMCpuMhzEstimate
            $Target.MaxFreeSpaceGB = $Target.MaxFreeSpaceGB - $VMDiskSpaceGB 

            # Perform the Live Migration (vMotion + Storage vMotion)
            # IMPORTANT: Uncomment the line below to enable actual migration
            #Move-VM -VM $VMToMove -Destination $Target.HostObj -Datastore $TargetDatastore -RunAsync | Out-Null
            
            Write-Log -Message "Successfully initiated Live Migration for $($VMToMove.Name) to $($Target.Name) (Datastore: $($TargetDatastore.Name))." -Level "INFO"
            
            # Crucial: Break the loop immediately after starting the first migration
            Write-Log -Message "Migration initiated. Breaking host analysis loop to prevent concurrent migrations."
            break
        }
        catch {
            Write-Log -Message "Migration failed for $($VMToMove.Name). Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }

}
finally {
    # 🛑 CRITICAL FIX FOR INTERACTIVE PROMPT: Forceful disconnect and suppression
    Write-Log -Message "Attempting to disconnect forcefully..."
    
    # Disconnect and ignore non-fatal errors to ensure script termination without user input.
    Disconnect-VIServer -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    
    Write-Log -Message "--- Script Execution Complete ---"
}
