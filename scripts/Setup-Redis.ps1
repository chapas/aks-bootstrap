
param(
    [string] $EnvName = "dev",
    [string] $SpaceName = "xiaodong"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$gitRootFolder = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
while (-not (Test-Path (Join-Path $gitRootFolder ".git"))) {
    $gitRootFolder = Split-Path $gitRootFolder -Parent
}
$scriptFolder = Join-Path $gitRootFolder "scripts"
if (-not (Test-Path $scriptFolder)) {
    throw "Invalid script folder '$scriptFolder'"
}

$envRootFolder = Join-Path $gitRootFolder "env"
$moduleFolder = Join-Path $scriptFolder "modules"
Import-Module (Join-Path $moduleFolder "Common2.psm1") -Force
Import-Module (Join-Path $moduleFolder "Logging.psm1") -Force
Import-Module (Join-Path $moduleFolder "CertUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "YamlUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "VaultUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "CosmosDb.psm1") -Force

InitializeLogger -ScriptFolder $scriptFolder -ScriptName "Setup-Redis"
LogStep -Message "Login and retrieve aks spn pwd..."
$bootstrapValues = Get-EnvironmentSettings -EnvName $envName -SpaceName $SpaceName -EnvRootFolder $envRootFolder
LoginAzureAsUser -SubscriptionName $bootstrapValues.global.subscriptionName | Out-Null

LogStep -Message "Ensure redis '$($bootstrapValues.redis.name)' is created..."
[array]$existingRedisFound = az redis list `
    --resource-group $bootstrapValues.redis.resourceGroup `
    --query "[?name=='$($bootstrapValues.redis.name)']" | ConvertFrom-Json
if ($null -eq $existingRedisFound -or $existingRedisFound.Count -eq 0) {
    $redis = az redis create `
        --name $bootstrapValues.redis.name `
        --resource-group $bootstrapValues.redis.resourceGroup `
        --location $bootstrapValues.redis.location `
        --sku $bootstrapValues.redis.sku `
        --vm-size $bootstrapValues.redis.vmSize | ConvertFrom-Json
    LogInfo -Message "redis '$($redis.hostName)' is created."
}
else {
    LogInfo -Message "Redis with name '$($bootstrapValues.redis.name)' is already created"
    $redis = $existingRedisFound[0]
}
LogInfo -Message "Storing secret '$($bootstrapValues.redis.accessKeySecret)' in key vault '$($bootstrapValues.kv.name)'..."
$accessKeys = az redis list-keys --name $bootstrapValues.redis.name --resource-group $bootstrapValues.redis.resourceGroup | ConvertFrom-Json
az keyvault secret set `
    --name $bootstrapValues.redis.accessKeySecret `
    --vault-name $bootstrapValues.kv.name `
    --value $accessKeys.primaryKey | Out-Null
