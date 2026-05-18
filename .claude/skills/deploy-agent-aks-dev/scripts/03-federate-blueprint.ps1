# Federate the AKS KSA directly to the Blueprint app.
# Subject = system:serviceaccount:agentid:agent-sa, Audience = api://AzureADTokenExchange.
# This is the only federation chain — no UAMI in the middle.

param(
  [Parameter(Mandatory=$true)] [string] $TenantId,
  [Parameter(Mandatory=$true)] [string] $BlueprintAppId,
  [Parameter(Mandatory=$true)] [string] $OidcIssuerUrl,
  [string] $Namespace = "agentid",
  [string] $ServiceAccount = "agent-sa",
  [string] $FicName = "aks-agent-sa"
)

$ErrorActionPreference = "Stop"

Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
Connect-MgGraph -TenantId $TenantId -Scopes "AgentIdentityBlueprint.AddRemoveCreds.All" -NoWelcome | Out-Null

$subject = "system:serviceaccount:$Namespace`:$ServiceAccount"
$body = @{
  name        = $FicName
  issuer      = $OidcIssuerUrl
  subject     = $subject
  audiences   = @("api://AzureADTokenExchange")
  description = "AKS KSA $subject"
} | ConvertTo-Json -Depth 5

$uri = "https://graph.microsoft.com/beta/applications(appId='$BlueprintAppId')/federatedIdentityCredentials"

try {
  Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType "application/json" | Out-Null
  Write-Host "Federated credential '$FicName' created on Blueprint $BlueprintAppId"
  Write-Host "  issuer  : $OidcIssuerUrl"
  Write-Host "  subject : $subject"
}
catch {
  if ($_.Exception.Message -match "already exists|FederatedIdentityCredential with the same") {
    Write-Host "Federated credential '$FicName' already exists — skipping."
  } else {
    throw
  }
}
