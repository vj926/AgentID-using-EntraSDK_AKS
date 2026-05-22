# setup-obo-blueprint-for-aks.ps1
# Configure the Blueprint app for the OBO (User.signedIn -> Agent) flow.
# This is the AKS copy of setup-obo-blueprint-for-aca.ps1 — content is identical
# because the Entra/Graph configuration is k8s-agnostic. The only reason it
# lives here too is so the AKS skill is self-contained and the PR ships the
# scripts alongside the manifests in this skill.
#
# What it does (all idempotent):
#   A. Set identifierUris = api://<BlueprintAppId>          (Blueprint app)
#   B. Add OAuth2 scope `access_as_user`                    (Blueprint app)
#   C. Verify result
#   D. Add Client SPA requiredResourceAccess: Blueprint/access_as_user
#   E. Pre-grant admin consent (oauth2PermissionGrant)      (Client SPA -> Blueprint)
#
# Cross-tenant: pass -TenantId for the Entra tenant where the Blueprint + SPA
# live (which can differ from the Azure subscription tenant — see
# references/cross-tenant-federation.md).
param(
    [Parameter(Mandatory=$true)][string]$BlueprintAppId,
    [Parameter(Mandatory=$true)][string]$TenantId,
    [Parameter(Mandatory=$true)][string]$ClientSpaAppId,
    [Parameter(Mandatory=$true)][string]$AgentAppId
)
$ErrorActionPreference='Stop'

Connect-MgGraph -Scopes 'AgentIdentityBlueprint.ReadWrite.All','Application.ReadWrite.All','AgentIdentityBlueprint.AddRemoveCreds.All','AgentIdentityBlueprint.Create','DelegatedPermissionGrant.ReadWrite.All','Application.Read.All','AgentIdentityBlueprintPrincipal.Create','AppRoleAssignment.ReadWrite.All','Directory.Read.All','User.Read' -TenantId $TenantId -NoWelcome | Out-Null

$appIdUri = "api://$BlueprintAppId"
$scopeId  = [guid]::NewGuid().ToString()
$bpUri    = "https://graph.microsoft.com/beta/applications(appId='$BlueprintAppId')"

Write-Host "Step A: identifierUris -> $appIdUri"
$body = @{ identifierUris = @($appIdUri) } | ConvertTo-Json -Depth 5
Invoke-MgGraphRequest -Method PATCH -Uri $bpUri -Body $body -ContentType 'application/json'

Write-Host "Step B: add access_as_user scope (id=$scopeId)"
$scopeBody = @{
    api = @{
        oauth2PermissionScopes = @(@{
            id = $scopeId
            adminConsentDescription = 'Access the agent on behalf of the signed-in user'
            adminConsentDisplayName = 'Access agent as user'
            isEnabled = $true
            type = 'User'
            userConsentDescription = 'Access the agent on your behalf'
            userConsentDisplayName = 'Access agent as user'
            value = 'access_as_user'
        })
    }
} | ConvertTo-Json -Depth 10
Invoke-MgGraphRequest -Method PATCH -Uri $bpUri -Body $scopeBody -ContentType 'application/json'

Write-Host "Step C: verify"
$bp = Invoke-MgGraphRequest -Method GET -Uri ($bpUri + '?$select=identifierUris,api')
$bp | ConvertTo-Json -Depth 10

Write-Host "Step D: add requiredResourceAccess on Client SPA"
$spaUri  = "https://graph.microsoft.com/v1.0/applications(appId='$ClientSpaAppId')"
$spaBody = @{
    requiredResourceAccess = @(@{
        resourceAppId  = $BlueprintAppId
        resourceAccess = @(@{ id = $scopeId; type = 'Scope' })
    })
} | ConvertTo-Json -Depth 10
Invoke-MgGraphRequest -Method PATCH -Uri $spaUri -Body $spaBody -ContentType 'application/json'

Write-Host "Step E: admin-consent oauth2PermissionGrant Client SPA -> Blueprint"
$spaSp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$ClientSpaAppId')?`$select=id"
$bpSp  = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals(appId='$BlueprintAppId')?`$select=id"
$grantBody = @{
    clientId    = $spaSp.id
    consentType = 'AllPrincipals'
    resourceId  = $bpSp.id
    scope       = 'access_as_user'
} | ConvertTo-Json
try {
    Invoke-MgGraphRequest -Method POST -Uri 'https://graph.microsoft.com/v1.0/oauth2PermissionGrants' -Body $grantBody -ContentType 'application/json' | Out-Null
    Write-Host "  Granted"
} catch {
    Write-Host "  Note (may already exist): $($_.Exception.Message)"
}

Write-Host "Done. scopeId=$scopeId"
