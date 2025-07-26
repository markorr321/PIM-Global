<#
  Global PIM Manager Script (Activation + Deactivation)
  -----------------------------------------------------
  - Detects and deactivates active roles (with justification)
  - Falls back to activation if no roles are active
  - Supports group-based and user-based eligibilities
  - MFA-enforced MSAL login via browser
#>

# ========================= Module Dependencies =========================
$ErrorActionPreference = "SilentlyContinue"

if (-not (Get-Module -Name MSAL.PS) -and -not (Get-Module -ListAvailable -Name MSAL.PS)) {
    Install-Module MSAL.PS -Scope CurrentUser -Force
}
if (-not (Get-Module -Name Microsoft.Graph) -and -not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# ========================= 1) Config & Login =========================
$clientId = "bf34fc64-bbbc-45cb-9124-471341025093"
$tenantId = "common"
$claimsJson = '{"access_token":{"acrs":{"essential":true,"value":"c1"}}}'
$extraParams = @{ "claims" = $claimsJson }

$scopesDelegated = @(
    "User.Read",
    "GroupMember.Read.All",
    "RoleManagement.Read.Directory",
    "RoleManagement.ReadWrite.Directory",
    "Directory.Read.All"
)

$tokenResult = Get-MsalToken -ClientId $clientId `
                             -TenantId $tenantId `
                             -Scopes $scopesDelegated `
                             -Interactive `
                             -Prompt SelectAccount `
                             -ExtraQueryParameters $extraParams

$accessToken = $tokenResult.AccessToken
$tenantId = $tokenResult.TenantId
$secureToken = ConvertTo-SecureString $accessToken -AsPlainText -Force
Connect-MgGraph -AccessToken $secureToken -ErrorAction Stop | Out-Null
$context = Get-MgContext
$currentUser = Get-MgUser -UserId $context.Account
$currentUserId = $currentUser.Id

Write-Host ""
Write-Host "✅ Connected with MFA-Compliant Token" -ForegroundColor DarkGreen
Write-Host "User: $($context.Account)" -ForegroundColor Cyan
Write-Host "Tenant: $tenantId" -ForegroundColor Cyan
Write-Host ""

function Flush-ConsoleInput {
    while ([Console]::KeyAvailable) {
        [Console]::ReadKey($true) | Out-Null
    }
}

# ========================= 2) Detect Active Roles =========================
# Use the working logic from PIM-Global.ps1 - simple direct assignment detection
$activeRoles = @()
$userAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All | Where-Object { $_.PrincipalId -eq $currentUserId }

foreach ($assignment in $userAssignments) {
    $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $assignment.RoleDefinitionId
    $activeRoles += [PSCustomObject]@{
        Assignment = $assignment
        RoleName   = $roleDef.DisplayName
    }
}

if ($activeRoles.Count -gt 0) {
    Write-Host "You currently have active PIM role(s):" -ForegroundColor Yellow
    $i = 1
    $activeMap = @{}
    foreach ($entry in $activeRoles) {
        $assignment = $entry.Assignment
        $scopeDisplay = if ($assignment.DirectoryScopeId -ne "/") { " (Scope: $($assignment.DirectoryScopeId))" } else { "" }
        Write-Host "[$i] $($entry.RoleName)$scopeDisplay"
        $activeMap[$i] = $entry
        $i++
    }

    Write-Host ""
    do {
        $resp = Read-Host "Would you like to deactivate one? (Y/N)"
        if ($resp -match '^[Yy]$') {
            break
        } elseif ($resp -match '^[Nn]$') {
            break
        } else {
            Write-Host "Please enter Y or N." -ForegroundColor DarkRed
        }
    } while ($true)
    
    if ($resp -match '^[Yy]$') {
        do {
            do {
                $selection = Read-Host "Enter the number(s) of the role(s) to deactivate (e.g., 1 or 1,2,3)"
                if ($selection -match '^[\d,]+$') {
                    $selectedNumbers = $selection -split ',' | ForEach-Object { $_.Trim() }
                    $validSelections = @()
                    $invalidSelections = @()
                    
                    foreach ($num in $selectedNumbers) {
                        if ($activeMap.ContainsKey([int]$num)) {
                            $validSelections += $activeMap[[int]$num]
                        } else {
                            $invalidSelections += $num
                        }
                    }
                    
                    if ($invalidSelections.Count -gt 0) {
                        Write-Host "Invalid selection(s): $($invalidSelections -join ', ')" -ForegroundColor DarkRed
                        $selection = $null
                    } elseif ($validSelections.Count -eq 0) {
                        Write-Host "No valid selections." -ForegroundColor DarkRed
                        $selection = $null
                    } else {
                        break
                    }
                } else {
                    Write-Host "Invalid format. Use numbers separated by commas (e.g., 1,2,3)" -ForegroundColor DarkRed
                    $selection = $null
                }
            } while (-not $selection)

            Flush-ConsoleInput

            do {
                $justification = Read-Host "Enter justification for deactivation"
                if ([string]::IsNullOrWhiteSpace($justification)) {
                    Write-Host "Justification required." -ForegroundColor DarkRed
                    $justification = $null
                }
            } while (-not $justification)

            $deactivationResults = @()
            $failedDeactivations = @()

            foreach ($toDeactivate in $validSelections) {
                $params = @{
                    Action           = "selfDeactivate"
                    PrincipalId      = $toDeactivate.Assignment.PrincipalId
                    RoleDefinitionId = $toDeactivate.Assignment.RoleDefinitionId
                    DirectoryScopeId = $toDeactivate.Assignment.DirectoryScopeId
                    Justification    = $justification
                    ScheduleInfo     = @{
                        StartDateTime = Get-Date
                    }
                }

                try {
                    $deactivationResult = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -BodyParameter $params -ErrorAction Stop
                    $deactivationResults += $toDeactivate.RoleName
                    Write-Host "✅ Role deactivation submitted for: $($toDeactivate.RoleName)" -ForegroundColor Magenta
                } catch {
                    $errorMessage = $_.Exception.Message
                    $cleanErrorMessage = $errorMessage
                    
                    if ($errorMessage -like "*ActiveDurationTooShort*" -or $errorMessage -like "*Active duration is too short*") {
                        $cleanErrorMessage = "Activation too short - Minimum 5 minutes required before deactivation!"
                    } elseif ($errorMessage -like "*JustificationRequired*" -or $errorMessage -like "*justification*") {
                        $cleanErrorMessage = "Justification is required for role deactivation"
                    } elseif ($errorMessage -like "*RoleAssignmentDoesNotExist*") {
                        $cleanErrorMessage = "The role assignment no longer exists"
                    }
                    
                    $failedDeactivations += "$($toDeactivate.RoleName): $cleanErrorMessage"
                }
            }

                if ($deactivationResults.Count -gt 0) {
        Write-Host ""
        Write-Host "Successfully deactivated: $($deactivationResults -join ', ')" -ForegroundColor Magenta
    }

                            if ($failedDeactivations.Count -gt 0) {
                Write-Host ""
                Write-Host "Failed deactivations:" -ForegroundColor Red
                foreach ($failure in $failedDeactivations) {
                    Write-Host "  $failure" -ForegroundColor Red
                }
            }

            Write-Host ""
            do {
                $continueChoice = Read-Host "Would you like to manage more roles? (Y/N)"
                if ($continueChoice -match '^[Yy]$') {
                    break
                } elseif ($continueChoice -match '^[Nn]$') {
                    Write-Host ""
                    Disconnect-MgGraph | Out-Null
                    Write-Host "Disconnected from Microsoft Graph." -ForegroundColor DarkRed
                    Write-Host ""
                    Write-Host "Press Enter to exit..." -ForegroundColor Cyan
                    $null = Read-Host
                    Stop-Process -Id $PID
                } else {
                    Write-Host "Please enter Y or N." -ForegroundColor DarkRed
                }
            } while ($true)

            Write-Host "Refreshing role status..." -ForegroundColor Cyan
            Start-Sleep -Seconds 3  # Give the API more time to reflect the deactivation
            $userAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All | Where-Object { $_.PrincipalId -eq $currentUserId }
            $activeRoles = @()
            foreach ($assignment in $userAssignments) {
                $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $assignment.RoleDefinitionId
                $activeRoles += [PSCustomObject]@{
                    Assignment = $assignment
                    RoleName   = $roleDef.DisplayName
                }
            }
            
            # Filter out roles that were just successfully deactivated
            $activeRoles = $activeRoles | Where-Object { $deactivationResults -notcontains $_.RoleName }

            if ($activeRoles.Count -gt 0) {
                Write-Host "You currently have active PIM role(s):" -ForegroundColor Yellow
                $i = 1
                $activeMap = @{}
                foreach ($entry in $activeRoles) {
                    $assignment = $entry.Assignment
                    $scopeDisplay = if ($assignment.DirectoryScopeId -ne "/") { " (Scope: $($assignment.DirectoryScopeId))" } else { "" }
                    Write-Host "[$i] $($entry.RoleName)$scopeDisplay"
                    $activeMap[$i] = $entry
                    $i++
                }

                do {
                    $deactivateAnother = Read-Host "Would you like to deactivate another role? (Y/N)"
                    if ($deactivateAnother -match '^[Yy]$') {
                        break
                    } elseif ($deactivateAnother -match '^[Nn]$') {
                        break
                    } else {
                        Write-Host "Please enter Y or N." -ForegroundColor DarkRed
                    }
                } while ($true)

                if ($deactivateAnother -match '^[Nn]$') {
                    break
                }
            } else {
                Write-Host "No more active roles to deactivate." -ForegroundColor Cyan
                break
            }
        } while ($true)
    }
}

# ========================= 3) Detect Eligible Roles =========================
if ($activeRoles.Count -eq 0) {
    Write-Host "No active roles found. Checking for eligible roles..." -ForegroundColor Cyan
} else {
    Write-Host "Checking for eligible roles..." -ForegroundColor Cyan
}
Write-Host ""

# Use the working logic from PIM-Global.ps1 - simple user-based eligibility detection
$myRoles = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -ExpandProperty RoleDefinition -All -Filter "principalId eq '$currentUserId'"
$validRoles = $myRoles | Where-Object { $_.RoleDefinition -and $_.RoleDefinition.DisplayName }

# Filter out roles that are already active for any principal
$validRoles = $validRoles | Where-Object {
    $roleDefId = $_.RoleDefinitionId
    $principalId = $_.PrincipalId
    
    # Check if this specific role is already active for this specific principal
    try {
        $existing = Get-MgRoleManagementDirectoryRoleAssignment `
            -Filter "principalId eq '$principalId' and roleDefinitionId eq '$roleDefId'"
        return -not $existing
    } catch {
        # If check fails, assume role is not active
        return $true
    }
}

if ($validRoles.Count -eq 0) {
    Write-Host "You do not have any eligible roles for activation." -ForegroundColor DarkRed
    Disconnect-MgGraph | Out-Null
    Write-Host "Disconnected from Microsoft Graph." -ForegroundColor DarkRed
    Write-Host ""
    Write-Host "Press Enter to exit..." -ForegroundColor Cyan
    $null = Read-Host
    Stop-Process -Id $PID
}

Write-Host "Available Eligible Roles for Activation:" -ForegroundColor Cyan
Write-Host ""
$index = 1
$roleMap = @{}
foreach ($role in $validRoles) {
    Write-Host ("[{0}] {1}" -f $index, $role.RoleDefinition.DisplayName)
    $roleMap[$index] = $role
    $index++
}

# ========================= 4) Activation Prompt & Submission =========================
do {
    Write-Host ""
    do {
        $selection = Read-Host "Enter the number(s) of the role(s) you want to activate (e.g., 1 or 1,2,3)"
        if ($selection -match '^[\d,]+$') {
            $selectedNumbers = $selection -split ',' | ForEach-Object { $_.Trim() }
            $validSelections = @()
            $invalidSelections = @()
            
            foreach ($num in $selectedNumbers) {
                if ($roleMap.ContainsKey([int]$num)) {
                    $validSelections += $roleMap[[int]$num]
                } else {
                    $invalidSelections += $num
                }
            }
            
            if ($invalidSelections.Count -gt 0) {
                Write-Host "Invalid selection(s): $($invalidSelections -join ', ')" -ForegroundColor DarkRed
                $selection = $null
            } elseif ($validSelections.Count -eq 0) {
                Write-Host "No valid selections." -ForegroundColor DarkRed
                $selection = $null
            } else {
                break
            }
        } else {
            Write-Host "Invalid format. Use numbers separated by commas (e.g., 1,2,3)" -ForegroundColor DarkRed
            $selection = $null
        }
    } while (-not $selection)

    Flush-ConsoleInput

    Write-Host ""
    do {
        $durationInput = Read-Host "Enter activation duration (e.g., 1H, 30M, 2H30M)"
        if ([string]::IsNullOrWhiteSpace($durationInput) -or $durationInput -notmatch '^\d+[HM]') {
            Write-Host "ERROR: Invalid format. Use '1H', '30M', or '2H30M'." -ForegroundColor DarkRed
            $durationInput = $null
        }
    } while (-not $durationInput)

    $duration = $durationInput.ToUpper() -replace '(\d+)H', 'PT${1}H' -replace '(\d+)M', '${1}M'
    if ($duration -match '^\d+M$') { $duration = "PT$duration" }

    Write-Host ""
    do {
        $justification = Read-Host "Enter reason for activation"
        if ([string]::IsNullOrWhiteSpace($justification)) {
            Write-Host "Justification required." -ForegroundColor DarkRed
            $justification = $null
        }
    } while (-not $justification)

    $activationResults = @()
    $failedActivations = @()
    
    foreach ($myRole in $validSelections) {
        $principalId = $myRole.PrincipalId
        
        try {
            # Check if the role is already active for this specific principal
            $existing = Get-MgRoleManagementDirectoryRoleAssignment `
                -Filter "principalId eq '$principalId' and roleDefinitionId eq '$($myRole.RoleDefinition.Id)'"
            
            if ($existing) {
                $failedActivations += "$($myRole.RoleDefinition.DisplayName): Role is already active for this principal"
                Write-Host "❌ Role activation failed for: $($myRole.RoleDefinition.DisplayName)" -ForegroundColor DarkRed
                Write-Host "  Role is already active for this principal" -ForegroundColor Yellow
                continue
            }
        } catch {
            # Continue if check fails
        }

        $directoryScopeId = if ([string]::IsNullOrEmpty($myRole.DirectoryScopeId)) { "/" } else { $myRole.DirectoryScopeId }

        $params = @{
            Action           = "selfActivate"
            PrincipalId      = $principalId
            RoleDefinitionId = $myRole.RoleDefinition.Id
            DirectoryScopeId = $directoryScopeId
            Justification    = $justification
            ScheduleInfo     = @{
                StartDateTime = Get-Date
                Expiration    = @{
                    Type     = "AfterDuration"
                    Duration = $duration
                }
            }
        }

        try {
            $activationResult = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -BodyParameter $params -ErrorAction Stop
            $activationResults += $myRole.RoleDefinition.DisplayName
            Write-Host "✅ Role activation submitted for: $($myRole.RoleDefinition.DisplayName)" -ForegroundColor Green
        } catch {
            $errorMessage = $_.Exception.Message
            $cleanErrorMessage = $errorMessage
            
            if ($errorMessage -like "*DurationTooShort*" -or $errorMessage -like "*duration is too short*") {
                $cleanErrorMessage = "Activation too short"
            } elseif ($errorMessage -like "*DurationTooLong*" -or $errorMessage -like "*duration is too long*") {
                $cleanErrorMessage = "The requested activation duration is too long. Maximum allowed duration: 8 hours"
            } elseif ($errorMessage -like "*JustificationRequired*" -or $errorMessage -like "*justification*") {
                $cleanErrorMessage = "Justification is required for role activation"
            } elseif ($errorMessage -like "*AlreadyActive*" -or $errorMessage -like "*already active*") {
                $cleanErrorMessage = "This role is already active for the specified principal"
            }
            
            $failedActivations += "$($myRole.RoleDefinition.DisplayName): $cleanErrorMessage"
        }
    }
    
    if ($activationResults.Count -gt 0) {
        $expiry = (Get-Date).Add([System.Xml.XmlConvert]::ToTimeSpan($duration))
        $formattedExpiry = $expiry.ToString("MM/dd/yyyy hh:mm:ss tt")
        
        Write-Host ""
        Write-Host "Successfully activated: $($activationResults -join ', ')" -ForegroundColor Green
        Write-Host "Expires at: $formattedExpiry" -ForegroundColor DarkCyan
    }
    
    if ($failedActivations.Count -gt 0) {
        Write-Host ""
        Write-Host "Failed activations:" -ForegroundColor Red
        foreach ($failure in $failedActivations) {
            Write-Host "  $failure" -ForegroundColor Red
        }
    }
    Write-Host ""
        
    # Check if there are more roles to activate
    Write-Host "Refreshing role status..." -ForegroundColor Cyan
    Start-Sleep -Seconds 2  # Give the API time to reflect the changes
    
    # Refresh active roles
    $userAssignments = Get-MgRoleManagementDirectoryRoleAssignment -All | Where-Object { $_.PrincipalId -eq $currentUserId }
    $activeRoles = @()
    foreach ($assignment in $userAssignments) {
        $roleDef = Get-MgRoleManagementDirectoryRoleDefinition -UnifiedRoleDefinitionId $assignment.RoleDefinitionId
        $activeRoles += [PSCustomObject]@{
            Assignment = $assignment
            RoleName   = $roleDef.DisplayName
        }
    }
    
    # Refresh eligible roles from API
    $myRoles = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -ExpandProperty RoleDefinition -All -Filter "principalId eq '$currentUserId'"
    
    # Filter out active roles from eligible roles
    $activeRoleIds = if ($activeRoles.Count -gt 0) {
        $activeRoles | ForEach-Object { $_.Assignment.RoleDefinitionId }
    } else {
        @()
    }
    
    # Also filter out roles that were just activated (even if API hasn't updated yet)
    $justActivatedRoleIds = $activationResults | ForEach-Object {
        $roleName = $_
        $myRoles | Where-Object { $_.RoleDefinition.DisplayName -eq $roleName } | Select-Object -ExpandProperty RoleDefinitionId
    }
    
    $validRoles = $myRoles | Where-Object { $_.RoleDefinition -and $_.RoleDefinition.DisplayName }
    $validRoles = $validRoles | Where-Object { 
        $activeRoleIds -notcontains $_.RoleDefinitionId -and 
        $justActivatedRoleIds -notcontains $_.RoleDefinitionId 
    }
    

    
    if ($validRoles.Count -gt 0) {
        # Ask if user wants to activate another role
        do {
            $activateAnother = Read-Host "Would you like to activate another role? (Y/N)"
            if ($activateAnother -match '^[Yy]$') {
                Write-Host ""
                Write-Host "Available Eligible Roles for Activation:" -ForegroundColor Cyan
                Write-Host ""
                $index = 1
                $roleMap = @{}
                foreach ($role in $validRoles) {
                    Write-Host ("[{0}] {1}" -f $index, $role.RoleDefinition.DisplayName)
                    $roleMap[$index] = $role
                    $index++
                }
                # Continue with activation logic
                break
                            } elseif ($activateAnother -match '^[Nn]$') {
                    Write-Host ""
                    Disconnect-MgGraph | Out-Null
                    Write-Host "Disconnected from Microsoft Graph." -ForegroundColor DarkRed
                    Write-Host ""
                    Write-Host "Press Enter to exit..." -ForegroundColor Cyan
                    $null = Read-Host
                    Stop-Process -Id $PID
            } else {
                Write-Host "Please enter Y or N." -ForegroundColor DarkRed
            }
        } while ($true)
        
        if ($activateAnother -match '^[Yy]$') {
            # Continue with activation logic
            continue
        }
            } else {
            Write-Host "No more eligible roles to activate." -ForegroundColor Cyan
            Write-Host ""
            Disconnect-MgGraph | Out-Null
            Write-Host "Disconnected from Microsoft Graph." -ForegroundColor DarkRed
            Write-Host ""
            Write-Host "Press Enter to exit..." -ForegroundColor Cyan
            $null = Read-Host
            Stop-Process -Id $PID
        }
} while ($true)

Disconnect-MgGraph | Out-Null
Write-Host "Disconnected from Microsoft Graph." -ForegroundColor DarkRed
Write-Host ""
Write-Host "Press Enter to exit..." -ForegroundColor Cyan
$null = Read-Host 