param(
    [string] $EnvName = "dev",
    [string] $SpaceName = "xiaodong"
)

$gitRootFolder = if ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
while (-not (Test-Path (Join-Path $gitRootFolder ".git"))) {
    $gitRootFolder = Split-Path $gitRootFolder -Parent
}
$scriptFolder = Join-Path $gitRootFolder "scripts"
if (-not (Test-Path $scriptFolder)) {
    throw "Invalid script folder '$scriptFolder'"
}
$envFolder = Join-Path $gitRootFolder "env"
$moduleFolder = Join-Path $scriptFolder "modules"

Import-Module (Join-Path $moduleFolder "YamlUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "Common2.psm1") -Force
Import-Module (Join-Path $moduleFolder "Logging.psm1") -Force
Import-Module (Join-Path $moduleFolder "CertUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "VaultUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "AcrUtil.psm1") -Force

InitializeLogger -ScriptFolder $scriptFolder -ScriptName "Setup-ContainerRegistry"
LogStep -Message "Retrieving environment settings for '$EnvName'..."
$bootstrapValues = Get-EnvironmentSettings -EnvName $envName -SpaceName $SpaceName -EnvRootFolder $envFolder
LoginAzureAsUser -SubscriptionName $bootstrapValues.global.subscriptionName | Out-Null
$rgName = $bootstrapValues.acr.resourceGroup
$location = $bootstrapValues.acr.location
az group create --name $rgName --location $location | Out-Null
$acrName = $bootstrapValues.acr.name
$vaultName = $bootstrapValues.kv.name
$acrPwdSecretName = $bootstrapValues.acr.passwordSecretName

# use ACR
LogStep -Message "Ensure ACR with name '$acrName' is setup..."
$acr = az acr show -g $rgName -n $acrName | ConvertFrom-Json
if (!$acr -or $acr.name -ne $acrName) {
    LogInfo -Message "Creating container registry $acrName..."
    az acr create -g $rgName -n $acrName --sku Basic | Out-Null
    $acr = az acr show -g $rgName -n $acrName | ConvertFrom-Json
}
else {
    LogInfo -Message "ACR with name '$acrName' already exists."
}


# login to azure
LogStep -Message "Granting service principal access to ACR..."
$acrId = $acr.id
$spnName = $bootstrapValues.global.servicePrincipal
$spn = az ad sp list --display-name $spnName | ConvertFrom-Json
$existingAssignments = az role assignment list --assignee $spn.appId --scope $acrId --role contributor | ConvertFrom-Json
if ($existingAssignments.Count -eq 0) {
    az role assignment create --assignee $spn.appId --scope $acrId --role contributor | Out-Null
}
else {
    LogInfo "Assignment already exists."
}
# NOTE: service principal authentication didn't work with acr after role assignment
# LoginAsServicePrincipal -EnvName $EnvName -ScriptFolder $envFolder


LogStep -Message "Login ACR '$acrName' and retrieve password..."
az acr login -n $acrName | Out-Null
az acr update -n $acrName --admin-enabled true | Out-Null


LogStep -Message "Save ACR password with name '$acrPwdSecretName' to KV '$vaultName'"
LogInfo -Message "Make sure docker is running"
# docker kill $(docker ps -q)
$acrUsername = $acrName
$acrPassword = "$(az acr credential show -n $acrName --query ""passwords[0].value"")"
LogInfo -Message "ACR: '$acrName', user: $acrUsername, password: ***"
LogInfo -Message "Store acr password to key vault '$vaultName' with name '$acrPwdSecretName'"
az keyvault secret set --vault-name $vaultName --name $acrPwdSecretName --value $acrPassword | Out-Null
