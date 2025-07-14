<#
  Unified Global PIM Script with ACRS-Compliant Interactive Login
  ----------------------------------------------------------------
  - Supports multi-tenant access
  - Performs MFA-enforced MSAL login (via browser)
  - Connects to Microsoft Graph with access token
  - Prompts user for eligible PIM role, duration, and justification
  - Submits PIM activation request
#>

# ========================= Module Dependencies =========================
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

try {
    $scopes = @("https://graph.microsoft.com/.default")
    $tokenResult = Get-MsalToken -ClientId $clientId `
                                 -TenantId $tenantId `
                                 -Scopes $scopes `
                                 -Interactive `
                                 -Prompt SelectAccount `
                                 -ExtraQueryParameters $extraParams

    $tenantId = $tokenResult.TenantId
    $accessToken = $tokenResult.AccessToken
    $secureToken = ConvertTo-SecureString $accessToken -AsPlainText -Force
    Connect-MgGraph -AccessToken $secureToken -ErrorAction Stop | Out-Null
    $context = Get-MgContext

    Write-Host ""
    Write-Host "Connected with MFA-Compliant Token" -ForegroundColor DarkGreen
    Write-Host "User: $($context.Account)" -ForegroundColor Cyan
    Write-Host "Tenant: $tenantId" -ForegroundColor Cyan
    Write-Host ""

    # Consent helper
    Write-Host "If access fails, your admin may need to grant consent to this app." -ForegroundColor Yellow
    Write-Host "Admin Consent URL: https://login.microsoftonline.com/common/adminconsent?client_id=$clientId" -ForegroundColor Cyan
    Write-Host ""

} catch {
    Write-Host ""
    Write-Host "[ERROR] Failed to authenticate: $_" -ForegroundColor DarkRed
    exit
}

# ========================= 2) Utility: Flush-ConsoleInput =========================
function Flush-ConsoleInput {
    while ([Console]::KeyAvailable) {
        [Console]::ReadKey($true) | Out-Null
    }
}

# ========================= 3) Get Eligible Roles =========================
$currentUser = (Get-MgUser -UserId $context.Account).Id
$myRoles = Get-MgRoleManagementDirectoryRoleEligibilitySchedule -ExpandProperty RoleDefinition -All -Filter "principalId eq '$currentUser'"
$validRoles = $myRoles | Where-Object { $_.RoleDefinition -and $_.RoleDefinition.DisplayName }

if ($validRoles.Count -eq 0) {
    Write-Host ""
    Write-Host "You do not have any eligible roles for activation." -ForegroundColor DarkRed
    Write-Host ""
    exit
}

Write-Host "Available Roles for Activation:" -ForegroundColor Cyan
Write-Host ""
$index = 1
$roleMap = @{ }
foreach ($role in $validRoles) {
    Write-Host ("[{0}] {1}" -f $index, $role.RoleDefinition.DisplayName)
    $roleMap[$index] = $role
    $index++
}

# ========================= 4) Prompt for Role =========================
Write-Host ""
do {
    $selection = Read-Host "Enter the number corresponding to the role you want to activate"
    if ([string]::IsNullOrWhiteSpace($selection) -or -not ($selection -match '^\d+$') -or [int]$selection -le 0 -or [int]$selection -gt $roleMap.Count) {
        Write-Host "ERROR: Invalid selection." -ForegroundColor DarkRed
        $selection = $null
    }
} while (-not $selection)

Flush-ConsoleInput
$myRole = $roleMap[[int]$selection]

# ========================= 5) Prompt for Duration =========================
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

# ========================= 6) Prompt for Justification =========================
Write-Host ""
do {
    $justification = Read-Host "Enter reason for activation"
    if ([string]::IsNullOrWhiteSpace($justification)) {
        Write-Host "ERROR: Justification required." -ForegroundColor DarkRed
        $justification = $null
    }
} while (-not $justification)

Flush-ConsoleInput

# ========================= 7) Check if Already Active =========================
try {
    $activeRoleAssignments = Get-MgRoleManagementDirectoryRoleAssignment `
        -Filter "principalId eq '$($myRole.PrincipalId)' and roleDefinitionId eq '$($myRole.RoleDefinitionId)'"
    if ($activeRoleAssignments) {
        Write-Host ""
        Write-Host "ERROR: Role is already active." -ForegroundColor DarkRed
        Write-Host ""
        Disconnect-MgGraph | Out-Null
        exit
    }
} catch {
    Write-Host ""
    Write-Host "Warning: Could not check existing assignment. Continuing..." -ForegroundColor Cyan
    Write-Host ""
}

# ========================= 8) Build & Submit Activation =========================
$directoryScopeId = if ([string]::IsNullOrEmpty($myRole.DirectoryScopeId)) { "/" } else { $myRole.DirectoryScopeId }

$params = @{
    Action           = "selfActivate"
    PrincipalId      = $myRole.PrincipalId
    RoleDefinitionId = $myRole.RoleDefinitionId
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
    $null = New-MgRoleManagementDirectoryRoleAssignmentScheduleRequest -BodyParameter $params
    $expiry = (Get-Date).Add([System.Xml.XmlConvert]::ToTimeSpan($duration))
    $formattedExpiry = $expiry.ToString("MM/dd/yyyy hh:mm:ss tt")

    Write-Host ""
    Write-Host "Role activation request submitted successfully!" -ForegroundColor DarkBlue
    Write-Host ""
    Write-Host "Activated Role: $($myRole.RoleDefinition.DisplayName)" -ForegroundColor Magenta
    Write-Host ""
    Write-Host "Role will expire at: $formattedExpiry" -ForegroundColor DarkCyan
    Write-Host ""
} catch {
    $msg = $_.Exception.Message
    Write-Host ""
    if ($msg -match "RoleAssignmentExists") {
        Write-Host "ERROR: Role is already active." -ForegroundColor DarkRed
    } elseif ($msg -match "PendingRoleAssignmentRequest") {
        Write-Host "ERROR: Pending request already exists." -ForegroundColor DarkRed
    } elseif ($msg -match "RoleAssignmentRequestAcrsValidationFailed") {
        Write-Host "ERROR: MFA session not valid (acrs=c1 not met)." -ForegroundColor DarkRed
    } else {
        Write-Host "ERROR: $msg" -ForegroundColor DarkRed
    }
    Write-Host ""
}

Disconnect-MgGraph | Out-Null
Write-Host "You have been disconnected from Microsoft Graph." -ForegroundColor DarkRed
Write-Host ""
