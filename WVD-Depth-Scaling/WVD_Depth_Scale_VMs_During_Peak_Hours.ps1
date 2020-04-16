<#
.SYNOPSIS
    Automated process of starting scaling 'X' number of WVD session hosts during peak-hours.
.DESCRIPTION
    This script is intended to automatically start 'X' session hosts in a Windows Virtual Desktop
    environment during peak-hours. The script pulls all session hosts underneath a WVD pool
    and runs the Start-AzVM command to start the desired session hosts. This runbook is triggered via
    a Azure Function running on a trigger.

    Please make sure your Azure Function is setup in the correct timezone by using the Applicaton Settings:

    WEBSITE_TIME_ZONE : YOUR TIME ZONE (Eastern Standard Time)

.NOTES
    Script is offered as-is with no warranty, expressed or implied.
    Test it before you trust it
    Author      : Brandon Babcock
    Website     : https://www.linkedin.com/in/brandonbabcock1990/
    Version     : 1.0.0.0 Initial Build
#>


######## Variables ##########

# Set default error action
$defaultErrorAction = $ErrorActionPreference

# Enable Verbose logging  
$VerbosePreference = 'SilentlyContinue'

# Server start threshold.  Number of available sessions to trigger a server start or shutdown
# (Active Sessions + Threshold) / Max Connections per session host
$serverStartThreshold = 1


# Update the following settings for your environment
# Tenant ID of Azure AD
$aadTenantId = Get-AutomationVariable -Name 'aadTenantId'

# Azure Subscription ID
$azureSubId = Get-AutomationVariable -Name 'azureSubId'

# Session Host Resource Group
$sessionHostRg = 'ahead-brandon-babcock-testwvd-rg'

# Tenant Name
$tenantName = 'bbbabcockwvd'

# Host Pool Name
$hostPoolName = 'hostpool1'

############## Functions ####################

Function Start-SessionHost {
    param (
        $SessionHosts
    )
    # Number of off session hosts accepting connections
    $offSessionHosts = $sessionHosts | Where-Object { $_.Status -eq "NoHeartBeat" }
    Write-Verbose "Off Session Hosts $offSessionHostsCount"
    Write-Verbose ($offSessionHosts | Out-String)

    if ($offSessionHosts.Count -eq 0 ) {
        Write-Error "Start threshold met, but there are no hosts available to start"
    }
    else {
        Write-Verbose "Conditions met to start a host"
        $startServerName = ($offSessionHosts | Select-Object -first 1).SessionHostName
        Write-Verbose "Server to start $startServerName"
        try {
            # Start the VM
            $creds = Get-AutomationPSCredential -Name 'WVD-Scaling-SVC'
            Connect-AzAccount -ErrorAction Stop -ServicePrincipal -SubscriptionId $azureSubId -TenantId $aadTenantId -Credential $creds
            $vmName = $startServerName.Split('.')[0]
            Start-AzVM -ErrorAction Stop -ResourceGroupName $sessionHostRg -Name $vmName
        }
        catch {
            $ErrorMessage = $_.Exception.message
            Write-Error ("Error starting the session host: " + $ErrorMessage)
            Break
        }
    }
}

Function Stop-SessionHost {
    param (
        $SessionHosts
    )

    # Get computers running with no users
    $emptyHosts = $sessionHosts | Where-Object { $_.Sessions -eq 0 -and $_.Status -eq 'Available' }

    Write-Verbose "Evaluating servers to shut down"
    if ($emptyHosts.count -eq 0) {
        Write-error "No hosts available to shut down"
    }
    elseif ($emptyHosts.count -ge 1) {
        Write-Verbose "Conditions met to stop a host"
        $shutServerName = ($emptyHosts | Select-Object -last 1).SessionHostName 
        Write-Verbose "Shutting down server $shutServerName"
        try {
            # Stop the VM
            $creds = Get-AutomationPSCredential -Name 'WVD-Scaling-SVC'
            Connect-AzAccount -ErrorAction Stop -ServicePrincipal -SubscriptionId $azureSubId -TenantId $aadTenantId -Credential $creds
            $vmName = $shutServerName.Split('.')[0]
            Stop-AzVM -ErrorAction Stop -ResourceGroupName $sessionHostRg -Name $vmName -Force
        }
        catch {
            $ErrorMessage = $_.Exception.message
            Write-Error ("Error stopping the VM: " + $ErrorMessage)
            Break
        }
    }   
}

########## Script Execution ##########

# Log into Azure WVD
try {
    $creds = Get-AutomationPSCredential -Name 'WVD-Scaling-SVC'
    Add-RdsAccount -ErrorAction Stop -DeploymentUrl "https://rdbroker.wvd.microsoft.com" -Credential $creds -ServicePrincipal -AadTenantId $aadTenantId
    Write-Verbose Get-RdsContext | Out-String
}
catch {
    $ErrorMessage = $_.Exception.message
    Write-Error ("Error logging into WVD: " + $ErrorMessage)
    Break
}

# Get Host Pool 
try {
    $hostPool = Get-RdsHostPool -ErrorVariable Stop $tenantName $hostPoolName 
    Write-Verbose "HostPool:"
    Write-Verbose $hostPool.HostPoolName
}
catch {
    $ErrorMessage = $_.Exception.message
    Write-Error ("Error getting host pool details: " + $ErrorMessage)
    Break
}

# Verify load balancing is set to Depth-first
if ($hostPool.LoadBalancerType -ne "DepthFirst") {
    Write-Error "Host pool not set to Depth-First load balancing.  This script requires Depth-First load balancing to execute"
    exit
}


# Get the Max Session Limit on the host pool
# This is the total number of sessions per session host
$maxSession = $hostPool.MaxSessionLimit
Write-Verbose "MaxSession:"
Write-Verbose $maxSession

# Find the total number of session hosts
# Exclude servers that do not allow new connections
try {
    $sessionHosts = Get-RdsSessionHost -ErrorAction Stop -tenant $tenantName -HostPool $hostPoolName | Where-Object { $_.AllowNewSession -eq $true }
}
catch {
    $ErrorMessage = $_.Exception.message
    Write-Error ("Error getting session hosts details: " + $ErrorMessage)
    Break
}

# Get current active user sessions
$currentSessions = 0
foreach ($sessionHost in $sessionHosts) {
    $count = $sessionHost.sessions
    $currentSessions += $count
}
Write-Verbose "CurrentSessions"
Write-Verbose $currentSessions

# Number of running and available session hosts
# Host shut down are excluded
$runningSessionHosts = $sessionHosts | Where-Object { $_.Status -eq "Available" }
$runningSessionHostsCount = $runningSessionHosts.count
Write-Verbose "Running Session Host $runningSessionHostsCount"
Write-Verbose ($runningSessionHosts | Out-string)

# Target number of servers required running based on active sessions, Threshold and maximum sessions per host
$sessionHostTarget = [math]::Ceiling((($currentSessions + $serverStartThreshold) / $maxSession))

if ($runningSessionHostsCount -lt $sessionHostTarget) {
    Write-Verbose "Running session host count $runningSessionHosts is less than session host target count $sessionHostTarget, run start function"
    Start-SessionHost -Sessionhosts $sessionHosts
}
elseif ($runningSessionHostsCount -eq $sessionHostTarget) {
    Write-Verbose "Running session hosts count $runningSessionHostsCount is greater than session host target count $sessionHostTarget, run stop function"
    Stop-SessionHost -SessionHosts $sessionHosts
}
elseif ($runningSessionHostsCount -gt $sessionHostTarget) {
    Write-Verbose "Running session hosts count $runningSessionHostsCount is greater than session host target count $sessionHostTarget, run stop function"
    Stop-SessionHost -SessionHosts $sessionHosts
}
else {
    Write-Verbose "Running session host count $runningSessionHostsCount matches session host target count $sessionHostTarget, doing nothing"
}
