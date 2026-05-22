# grant-agent-obo-consent.ps1
# Grant the Agent service principal the delegated Graph permission `User.Read`
# at admin-consent level. Fixes AADSTS65001 on the OBO sign-in flow.
#
# This is the AKS copy of grant-agent-obo-consent.ps1 — content is identical to
# the ACA version because the Entra/Graph operation is k8s-agnostic. It lives
# here too so the AKS skill is self-contained and the PR ships it alongside the
# manifests in this skill's manifests/ directory.
#
# Cross-tenant: -TenantId is the Entra tenant where the Agent app lives (which
# can differ from the Azure subscription tenant).
param(
    [Parameter(Mandatory=$true)][string]$AgentAppId,
    [Parameter(Mandatory=$true)][string]$TenantId
)
$ErrorActionPreference='Stop'
Connect-MgGraph -Scopes 'AppRoleAssignment.ReadWrite.All','DelegatedPermissionGrant.ReadWrite.All','Application.Read.All','Directory.Read.All' -TenantId $TenantId -NoWelcome | Out-Null

$agentSp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$AgentAppId')?`$select=id,displayName"
Write-Host "Agent SP: $($agentSp.id)  ($($agentSp.displayName))"

$graphSp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='00000003-0000-0000-c000-000000000000')?`$select=id"
Write-Host "Graph SP: $($graphSp.id)"

$existing = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants?`$filter=clientId eq '$($agentSp.id)' and resourceId eq '$($graphSp.id)'"
Write-Host "Existing grants: $($existing.value.Count)"
$existing.value | ForEach-Object { Write-Host "  scope='$($_.scope)' consentType=$($_.consentType)" }

# IMPORTANT: a Principal-typed (per-user) grant does NOT satisfy other users'
# OBO calls — they'll still hit AADSTS65001. Only short-circuit when a
# tenant-wide AllPrincipals grant already covers User.Read.
$hasAllPrincipalsUserRead = $existing.value | Where-Object {
    $_.consentType -eq 'AllPrincipals' -and $_.scope -match '(^|\s)User\.Read(\s|$)'
} | Select-Object -First 1
if ($hasAllPrincipalsUserRead) {
    Write-Host "✅ Tenant-wide (AllPrincipals) User.Read already granted ($($hasAllPrincipalsUserRead.scope)). Nothing to do."
    return
}

$hasPrincipalOnly = $existing.value | Where-Object { $_.consentType -eq 'Principal' -and $_.scope -match 'User\.Read' } | Select-Object -First 1
if ($hasPrincipalOnly) {
    Write-Host "⚠️  Found a Principal (per-user) grant for User.Read — this does NOT cover other users. Adding tenant-wide AllPrincipals grant now..."
}

$body = @{
    clientId    = $agentSp.id
    consentType = 'AllPrincipals'
    resourceId  = $graphSp.id
    scope       = 'User.Read'
} | ConvertTo-Json
$r = Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body $body -ContentType 'application/json'
Write-Host "Granted. id=$($r.id) scope='$($r.scope)'"
