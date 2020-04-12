

param(
	[Parameter(mandatory = $True)]
	[string]$SubscriptionId,

	[Parameter(mandatory = $True)]
	[string]$ResourceGroupName,

	[Parameter(mandatory = $True)]
	$AutomationAccountName,

    [Parameter(mandatory = $True)]
	[string]$AzureRunbookWebHookName,

	[Parameter(mandatory = $True)]
	[string]$Location

)

#Initializing variables
$ScriptRepoLocation = "https://raw.githubusercontent.com/bbabcock1990/WVD-Scaling-Scripts/master/WVD-Depth-Scaling"


# Set the ExecutionPolicy
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser -Force -Confirm:$false

# Setting ErrorActionPreference to stop script execution when error occurs
$ErrorActionPreference = "Stop"

# Import Az Modules
Import-Module Az.Resources
Import-Module Az.Accounts
Import-Module Az.OperationalInsights
Import-Module Az.Automation


# Get the azure context
$Context = Get-AzContext
if ($Context -eq $null)
{
	Write-Error "Please authenticate to Azure using Login-AzAccount cmdlet and then run this script"
	exit
}

# Select the subscription
$Subscription = Select-azSubscription -SubscriptionId $SubscriptionId
Set-AzContext -SubscriptionObject $Subscription.ExtendedProperties

# Get the Role Assignment of the authenticated user. User must have Role at RG or Subscription level.
$RoleAssignment = (Get-AzRoleAssignment -SignInName $Context.Account)

if ($RoleAssignment.RoleDefinitionName -eq "Owner" -or $RoleAssignment.RoleDefinitionName -eq "Contributor")
{

	#Check if the resourcegroup exist
	$ResourceGroup = Get-AzResourceGroup -Name $ResourceGroupName -Location $Location -ErrorAction SilentlyContinue
	if ($ResourceGroup -eq $null) {
		New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Force -Verbose
		Write-Output "Resource Group was created with name $ResourceGroupName"
	}

	#Check if the Automation Account exist
	$AutomationAccount = Get-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -ErrorAction SilentlyContinue
	if ($AutomationAccount -eq $null) {
		New-AzAutomationAccount -ResourceGroupName $ResourceGroupName -Name $AutomationAccountName -Location $Location -Plan Free -Verbose
		Write-Output "Automation Account was created with name $AutomationAccountName"
	}

	$RequiredModules = @(
		[pscustomobject]@{ ModuleName = 'Az.Accounts'; ModuleVersion = '1.6.4' }
		[pscustomobject]@{ ModuleName = 'Microsoft.RDInfra.RDPowershell'; ModuleVersion = '1.0.1288.1' }
		[pscustomobject]@{ ModuleName = 'OMSIngestionAPI'; ModuleVersion = '1.6.0' }
		[pscustomobject]@{ ModuleName = 'Az.Compute'; ModuleVersion = '3.1.0' }
		[pscustomobject]@{ ModuleName = 'Az.Resources'; ModuleVersion = '1.8.0' }
		[pscustomobject]@{ ModuleName = 'Az.Automation'; ModuleVersion = '1.3.4' }
	)

	#Function to add required modules to Azure Automation account
	function AddingModules-toAutomationAccount {
		param(
			[Parameter(mandatory = $true)]
			[string]$ResourceGroupName,

			[Parameter(mandatory = $true)]
			[string]$AutomationAccountName,

			[Parameter(mandatory = $true)]
			[string]$ModuleName,

			# if not specified latest version will be imported
			[Parameter(mandatory = $false)]
			[string]$ModuleVersion
		)


		$Url = "https://www.powershellgallery.com/api/v2/Search()?`$filter=IsLatestVersion&searchTerm=%27$ModuleName $ModuleVersion%27&targetFramework=%27%27&includePrerelease=false&`$skip=0&`$top=40"

		[array]$SearchResult = Invoke-RestMethod -Method Get -Uri $Url
		if ($SearchResult.Count -ne 1) {
			$SearchResult = $SearchResult[0]
		}

		if (!$SearchResult) {
			Write-Error "Could not find module '$ModuleName' on PowerShell Gallery."
		}
		elseif ($SearchResult.Count -and $SearchResult.Length -gt 1) {
			Write-Error "Module name '$ModuleName' returned multiple results. Please specify an exact module name."
		}
		else {
			$PackageDetails = Invoke-RestMethod -Method Get -Uri $SearchResult.Id

			if (!$ModuleVersion) {
				$ModuleVersion = $PackageDetails.entry.properties.version
			}

			$ModuleContentUrl = "https://www.powershellgallery.com/api/v2/package/$ModuleName/$ModuleVersion"

			# Test if the module/version combination exists
			try {
				Invoke-RestMethod $ModuleContentUrl -ErrorAction Stop | Out-Null
				$Stop = $False
			}
			catch {
				Write-Error "Module with name '$ModuleName' of version '$ModuleVersion' does not exist. Are you sure the version specified is correct?"
				$Stop = $True
			}

			if (!$Stop) {

				# Find the actual blob storage location of the module
				do {
					$ActualUrl = $ModuleContentUrl
					$ModuleContentUrl = (Invoke-WebRequest -Uri $ModuleContentUrl -MaximumRedirection 0 -UseBasicParsing -ErrorAction Ignore).Headers.Location
				} while ($ModuleContentUrl -ne $Null)

				New-AzAutomationModule `
 					-ResourceGroupName $ResourceGroupName `
 					-AutomationAccountName $AutomationAccountName `
 					-Name $ModuleName `
 					-ContentLink $ActualUrl
			}
		}
	}

	#Function to check if the module is imported
	function Check-IfModuleIsImported {
		param(
			[Parameter(mandatory = $true)]
			[string]$ResourceGroupName,

			[Parameter(mandatory = $true)]
			[string]$AutomationAccountName,

			[Parameter(mandatory = $true)]
			[string]$ModuleName
		)

		$IsModuleImported = $false
		while (!$IsModuleImported) {
			$IsModule = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $ModuleName -ErrorAction SilentlyContinue
			if ($IsModule.ProvisioningState -eq "Succeeded") {
				$IsModuleImported = $true
				Write-Output "Successfully $ModuleName module imported into Automation Account Modules..."
			}
			else {
				Write-Output "Waiting for to import module $ModuleName into Automation Account Modules ..."
			}
		}
	}

	#Creating a runbook and published the Scale Scripts
	$DeploymentStatus01 = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateUri "$ScriptRepoLocation/Azure_Automation_Runbook_Template.json" -existingAutomationAccountName $AutomationAccountName -RunbookName 'WVD_Depth_Scale_VMs_During_Peak_Hours' -RunbookScript '/WVD_Depth_Scale_VMs_During_Peak_Hours.ps1' -Force -Verbose
	
    $DeploymentStatus02 = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateUri "$ScriptRepoLocation/Azure_Automation_Runbook_Template.json" -existingAutomationAccountName $AutomationAccountName -RunbookName 'WVD_Depth_Start_VMs_Before_Peak_Hours' -RunbookScript '/WVD_Depth_Start_VMs_Before_Peak_Hours.ps1' -Force -Verbose

    $DeploymentStatus03 = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateUri "$ScriptRepoLocation/Azure_Automation_Runbook_Template.json" -existingAutomationAccountName $AutomationAccountName -RunbookName 'WVD_Depth_Stop_VMs_After_Peak_Hours' -RunbookScript '/WVD_Depth_Stop_VMs_After_Peak_Hours.ps1' -Force -Verbose
    
    if ($DeploymentStatus01.ProvisioningState -eq "Succeeded") {

		#Check if the Webhook URI exists in automation variable
		$WebhookURI = Get-AzAutomationVariable -Name "WebhookURI" -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ErrorAction SilentlyContinue
		if (!$WebhookURI) {
			$Webhook = New-AzAutomationWebhook -Name $AzureRunbookWebHookName -RunbookName 'WVD_Depth_Scale_VMs_During_Peak_Hours' -IsEnabled $True -ExpiryTime (Get-Date).AddYears(5) -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Force
			Write-Output "Automation Account Webhook is created with name '$AzureRunbookWebHookName'"
			$URIofWebhook = $Webhook.WebhookURI | Out-String
			New-AzAutomationVariable -Name "WebhookURI" -Encrypted $false -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Value $URIofWebhook
			Write-Output "Webhook URI stored in Azure Automation Acccount variables"
			$WebhookURI = Get-AzAutomationVariable -Name "WebhookURI" -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ErrorAction SilentlyContinue
		}
	}





	#}
	# Required modules imported from Automation Account Modules gallery for Scale Script execution
	foreach ($Module in $RequiredModules) {
		# Check if the required modules are imported 
		$ImportedModule = Get-AzAutomationModule -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -Name $Module.ModuleName -ErrorAction SilentlyContinue
		if ($ImportedModule -eq $Null) {
			AddingModules-toAutomationAccount -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ModuleName $Module.ModuleName
			Check-IfModuleIsImported -ModuleName $Module.ModuleName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName
		}
		elseif ($ImportedModule.version -ne $Module.ModuleVersion) {
			AddingModules-toAutomationAccount -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName -ModuleName $Module.ModuleName
			Check-IfModuleIsImported -ModuleName $Module.ModuleName -ResourceGroupName $ResourceGroupName -AutomationAccountName $AutomationAccountName
		}
	}
	
	Write-Output "Automation Account Name:$AutomationAccountName"
	Write-Output "Webhook URI: $($WebhookURI.value)"
	
}
else
{
	Write-Output "Authenticated user should have the Owner/Contributor permissions"
}
