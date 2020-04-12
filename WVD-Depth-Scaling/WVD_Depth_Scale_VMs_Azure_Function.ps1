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
[int]$hour = (get-date -format HH)#-6 #Convert UTC TO CST -6
[string]$day=(get-date).DayOfWeek


#Check the day against working days
if ($day -ne 'Saturday' -and $day -ne 'Sunday')
{
    Write-Output "The Day Is: $day"
    If($hour -lt 8 -or $hour -gt 17)
    { 
        Write-output "Currently Not In Peak Hours" 
        Write-Output "Not Scaling-All Hosts Should Be Shut Down via Azure Automation"
    }
    else
    {
        #If working hours and working days, scale WVD Hosts
        Write-Output "Currently In Peak Hours and Scaling via Azure Automation"
        Invoke-WebRequest -Uri "https://s1events.azure-automation.net/webhooks?token=0dAbqUUxcbuD1%2fzJgLwK0tOuL7QG7Kly64VJlVjmgYk%3d" -Method POST
    }
}
else
{
    Write-Output "The Day Is: $Day"
    Write-Output "Not Scaling-All Hosts Should Be Shut Down via Azure Automation"
}

