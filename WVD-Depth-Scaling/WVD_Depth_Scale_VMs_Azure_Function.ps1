<#
.SYNOPSIS
    Automated process of scaling WVD session hosts during peak-hours and work days.
.DESCRIPTION
    This script is intended to automatically scale session hosts in a Windows Virtual Desktop
    environment during peak-hours and work days using Azure Functions. The script checks the 
    time and day and validates the peak hours and work days before sending a webhook to scale 
    WVD hosts.

.INSTALL
    Make sure the Azure Function has the following Cron Trigger (5 Minutes)
    {
    "bindings": [
        {
          "name": "Timer",
          "type": "timerTrigger",
          "direction": "in",
          "schedule": "0 */5 * * * *"
        }
      ]
    }
    
.NOTES
    Script is offered as-is with no warranty, expressed or implied.
    Test it before you trust it
    Author      : Brandon Babcock
    Website     : https://www.linkedin.com/in/brandonbabcock1990/
    Version     : 1.0.0.0 Initial Build
#>

# Input bindings are passed in via param block.
param($Timer)

######## Variables ##########

# Business Start and Stop Hours
[int]$startHour = 8
[int]$stopHour = 17

# Business Work Days
[array]$workDays='Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'

# Pulling the current hour and day
[int]$currenthour = (get-date -format HH)
[string]$currentDay = (get-date).DayOfWeek


# Check the current day against working days
if ($currentDay -in $workDays)
{
 
    If($currentHour -lt $startHour -or $currentHour -gt $stopHour)
    { 
        # If not within working hours, do nothing
        Write-Host "We are currently NOT in peak hours"
        Write-Host "The current day/hour is: " $currentDay ":" $currenthour
        Write-Host "Not scaling hosts. All hosts should be shut down via Azure Automation"
    }
    else
    {
        # If within hours, scale WVD Hosts
        Write-Host "We are currently IN peak hours"
        Write-Host "The current day/hour is: " $currentDay ":" $currenthour
        Write-Host "Currently scaling hosts via Azure Automation"
        Invoke-WebRequest -Uri "https://s1events.azure-automation.net/webhooks?token=%2f1gN2GS1h9VvTnrsYkh%2fypfZ5oSBbKnnARanREFinXQ%3d" -Method POST
    }
}
else
{
    # If not within working days, do nothing
    Write-Host "We are currently NOT in peak hours or working days"
    Write-Host "The current day/hour is: " $currentDay ":" $currenthour
    Write-Host "Not scaling hosts. All hosts should be shut down via Azure Automation"
}

