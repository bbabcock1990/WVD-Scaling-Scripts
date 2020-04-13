<#
.SYNOPSIS
    Automated process of starting 'X' number of WVD session hosts before peak-hours.
.DESCRIPTION
    This script is intended to automatically start 'X" session hosts in a Windows Virtual Desktop
    environment before peak-hours. The script pulls all session hosts underneath a WVD pool
    and runs the Start-AzVM command to start the desired session hosts. This runbook is triggered via
    a Azure Automation running on a schedule.
    
.NOTES
    Script is offered as-is with no warranty, expressed or implied.
    Test it before you trust it
    Author      : Brandon Babcock
    Website     : https://www.linkedin.com/in/brandonbabcock1990/
    Version     : 1.0.0.0 Initial Build
#>

######## Variables ##########

#AD and Sub IDs Pulled From Runbook Variables
$aadTenantId = Get-AutomationVariable -Name 'aadTenantId'
$azureSubId = Get-AutomationVariable -Name 'azureSubId'

# Session Host Resource Group
$sessionHostRg = 'ahead-brandon-babcock-testwvd-rg'

# Tenant Name
$tenantName = 'bbbabcockwvd'

# Host Pool Name
$hostPoolName = 'hostpool1'

# Amount of Sessions Hosts To Start
$sessionHostCount = 5

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

# Log into Azure
try {
    $creds = Get-AutomationPSCredential -Name 'WVD-Scaling-SVC'
    Connect-AzAccount -ErrorAction Stop -ServicePrincipal -SubscriptionId $azureSubId -TenantId $aadTenantId -Credential $creds
    Write-Verbose Get-RdsContext | Out-String
}
catch {
    $ErrorMessage = $_.Exception.message
    Write-Error ("Error logging into Azure: " + $ErrorMessage)
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

# Get List Of All Session Host Under Host Pool
$sessionHostList = Get-RdsSessionHost -TenantName $tenantName -HostPoolName $hostPoolName

# Start 'X' Session Host. Session Host >= 'X'
try{
    For ($i=0; $i -lt ($sessionHostCount); $i++) {
        Write-Output $sessionHostList[$i].SessionHostName.Split('.')[0]
        Start-AzVM -ErrorAction Stop -ResourceGroupName $sessionHostRg -Name $sessionHostList[$i].SessionHostName.Split('.')[0] -AsJob
    }
}
catch{
    $ErrorMessage = $_.Exception.message
    Write-Error ("Error starting VMs: " + $ErrorMessage)
    Break
}

