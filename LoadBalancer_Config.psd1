#
# LoadBalancer_Config.psd1
# Configuration file for the Auto Load Balancer Script
#

@{
    # vCenter Connection Settings
    vCenterServer = "10.10.10.10"
    Username = "Administrator"
    Password = "XXXXXXXXX" # IMPORTANT: Consider using a safer method for password storage.

    # Resource Usage Thresholds (in percentage)
    CpuThreshold = 80
    MemThreshold = 80
	DatastoreThresholdPct = 85

    # Time interval for calculating average resource statistics (in seconds, e.g., 300s = 5 minutes)
    StatInterval = 300 

    # --- Multiple Local Datastore Name Patterns (CRITICAL CHANGE) ---
    # This must be an array of patterns. The script will look for Datastores matching ANY of these patterns.
    # Example: @("Local_SSD*", "ESXi_SATA_Disk*", "HostName-Local-LUN")
    LocalDatastorePattern = @(
        "ESXi*"
    )

    # Logging Settings
    LogDirectory = "D:\VMware_Logs\Auto_Load_Balancer"

    # --- Exclusion Settings ---
    
    # List of Host names to exclude from the Load Balancing analysis.
    # Use commas to separate multiple hosts (Example: "ESXi-DR-01", "ESXi-Test-05")
    ExcludeHostNames = @(
        "ESXi-DR-01"
    )

    # List of VM names that should not be selected for migration (vMotion).
    # (Example: "Domain-Controller", "vCenter-Server")
    ExcludeVMNames = @(
        "Domain-Controller"
    )
}
