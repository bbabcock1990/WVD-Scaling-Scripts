<#
.SYNOPSIS
    Automated process of starting and stopping WVD session hosts based on user sessions.
.DESCRIPTION
    This script is intended to automatically start and stop session hosts in a Windows Virtual Desktop
    environment based on the number of users.  
    The script determines the number of servers that should be running by adding the number of session 
    in the pool to a threshold. The threshold is the number of sessions that should be available between each script run.
    Those two numbers are added and divided by the maximum sessions per host.  The maximum session is set in the 
    depth-first load balancing settings.  Session hosts are stopped or started based on that number.
    Requirements:
    An Azure Automation and an Azure Function account.
    Azure Automation requires the az.accounts, az.compute and Microsoft.RDInfra.RDPowershell modules
    WVD Host Pool must be set to Depth First
    WVD deployed with a Service Principle
    WVD Service Principle has contributor rights to the session host resource group
    Credential object in Azure Automation with Service Principle username and Password
    Set a GPO for the session hosts to log out disconnected and idle sessions
    Full details can be found at:
    https://www.ciraltos.com/automatically-start-and-stop-wvd-vms-with-azure-automation/
.NOTES
    Script is offered as-is with no warranty, expressed or implied.
    Test it before you trust it
    Author      : Travis Roberts
    Website     : www.ciraltos.com
    Version     : 1.0.0.0 Initial Build
#>


######## Variables ##########

# Set default error action
$defaultErrorAction = $ErrorActionPreference

# Enable Verbose logging  
$VerbosePreference = 'SilentlyContinue'

# Server start threshold.  Number of available sessions to trigger a server start or shutdown
$serverStartThreshold = 2

# Peak time and Threshold settings
# Set the usePeak to yes or no. 
# Modify the peak threshold, start, stop, and peakDays as needed
# Set utcOffset to your local time zone
# Set usePeak to "yes" to enable peak time
$usePeak = "no"
# Peak server start threshold
$peakServerStartThreshold = 4
$startPeakTime = '08:00:00'
$endPeakTime = '18:00:00'
$utcOffset = '-6'
# Peak week days
$peakDay = 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday'


# Update the following settings for your environment
# Tenant ID of Azure AD
#$aadTenantId = '<Enter Tenant ID>'
# Or use an Azure Automation Encrypted Variable
$aadTenantId = Get-AutomationVariable -Name 'aadTenantId'

# Azure Subscription ID
#$azureSubId = '<Enter Tenanat ID>'
# Or use an Azure Automation Encrypted Variable
$azureSubId = Get-AutomationVariable -Name 'azureSubId'

# Session Host Resource Group
$sessionHostRg = 'WVDHP01'

# Tenant Name
$tenantName = 'Ciraltos'

# Host Pool Name
$hostPoolName = 'HostPool01'

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
            $creds = Get-AutomationPSCredential -Name 'WVDSvcPrincipal'
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

function Stop-SessionHost {
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
        $shutServerName = ($emptyHosts | Select-Object -first 1).SessionHostName 
        Write-Verbose "Shutting down server $shutServerName"
        try {
            # Stop the VM
            $creds = Get-AutomationPSCredential -Name 'WVDSvcPrincipal'
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
    $creds = Get-AutomationPSCredential -Name 'WVDSvcPrincipal'
    Add-RdsAccount -ErrorAction Stop -DeploymentUrl "https://rdbroker.wvd.microsoft.com" -Credential $creds -ServicePrincipal -AadTenantId $aadTenantId
    Write-verbose Get-RdsContext | Out-String
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

# Check if peak time and adjust threshold
$date = ((get-date).ToUniversalTime()).AddHours($utcOffset)
$dateTime = ($date.hour).ToString() + ':' + ($date.minute).ToString() + ':' + ($date.second).ToString()
write-verbose "Date and Time"
write-verbose $dateTime
$dateDay = (((get-date).ToUniversalTime()).AddHours($utcOffset)).dayofweek
Write-Verbose $dateDay
if ($dateTime -gt $startPeakTime -and $dateTime -lt $endPeakTime -and $dateDay -in $peakDay -and $usePeak -eq "yes") {
    Write-Verbose "Adjusting threshold for peak hours"
    $serverStartThreshold = $peakServerStartThreshold
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
elseif ($runningSessionHostsCount -gt $sessionHostTarget) {
    Write-Verbose "Running session hosts count $runningSessionHostsCount is greater than session host target count $sessionHostTarget, run stop function"
    Stop-SessionHost -SessionHosts $sessionHosts
}
else {
    Write-Verbose "Running session host count $runningSessionHostsCount matches session host target count $sessionHostTarget, doing nothing"
}
