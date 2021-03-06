
param(
    [ValidateSet("dev", "int", "prod")]
    [string] $EnvName = "dev",
    [string] $SpaceName = "xiaodong",
    [bool] $IsLocal = $false,
    [bool] $UsePodIdentity = $true,
    [string] $BuildNumber = $(Get-Date -f "yyyyMMddHHmm"),
    [string] $ServiceTemplateFile = "~/work/github/aks-bootstrap/deploy/examples/1es/services.yaml",
    [string[]] $ServicesToDeploy = @("all")
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
$yamlsFolder = Join-Path $ScriptFolder "yamls"
if (-not (Test-Path $yamlsFolder)) {
    New-Item $yamlsFolder -ItemType Directory -Force | Out-Null
}
$envRootFolder = Join-Path $gitRootFolder "env"
$templateFolder = Join-Path $envRootFolder "templates"
$moduleFolder = Join-Path $scriptFolder "modules"

if ($null -eq $ServiceTemplateFile -or (-not (Test-Path $ServiceTemplateFile))) {
    throw "Unable to find service template file '$ServiceTemplateFile'"
}

Import-Module (Join-Path $moduleFolder "Common2.psm1") -Force
Import-Module (Join-Path $moduleFolder "Logging.psm1") -Force
Import-Module (Join-Path $moduleFolder "CertUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "YamlUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "VaultUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "KubeUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "AksUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "ServiceUtil.psm1") -Force
Import-Module (Join-Path $moduleFolder "AcrUtil.psm1") -Force

InitializeLogger -ScriptFolder $scriptFolder -ScriptName "Deploy-AppsInCluster"
UsingScope("Connecting to AKS cluster") {
    $bootstrapValues = Get-EnvironmentSettings -EnvName $envName -EnvRootFolder $envRootFolder -SpaceName $SpaceName
    $azAccount = LoginAzureAsUser -SubscriptionName $bootstrapValues.global.subscriptionName
    LogStep -Message "Build/deploy services using $($azAccount.user.name) [$($azAccount.user.type)]"
    & $scriptFolder\ConnectTo-AksCluster.ps1 -EnvName $EnvName -SpaceName $SpaceName -AsAdmin
}


UsingScope("Login to acr") {
    $acr = az acr show -g $bootstrapValues.acr.resourceGroup -n $bootstrapValues.acr.name | ConvertFrom-Json
    LogStep "login acr '$($acr.loginServer)'"
    az acr login -n $bootstrapValues.acr.name
}

UsingScope("Create K8S secret for docker registry") {
    $existingAcrAuthSecret = kubectl get secret acr-auth -o json | ConvertFrom-Json
    if ($null -ne $existingAcrAuthSecret) {
        LogStep "ACR secret 'acr-auth' is already created"
    }
    else {
        $acrPassword = "$(az acr credential show -n $($bootstrapValues.acr.name) --query ""passwords[0].value"")"
        $acrOwnerEmail = $bootstrapValues.acr.email
        $acrLoginServer = $acr.loginServer
        Write-Host "2. Setup ACR connection as secret in AKS..."
        kubectl create secret docker-registry acr-auth `
            --docker-server $acrLoginServer `
            --docker-username $bootstrapValues.acr.name `
            --docker-password $acrPassword `
            --docker-email $acrOwnerEmail -n default
    }
}


LogStep -Message "Cleaning existing docker images on local disk..."
ClearLocalDockerImages


$serviceTemplates = Get-Content $ServiceTemplateFile -Raw | ConvertFrom-Yaml -Ordered
LogStep -Message "Build and deploy all $($serviceTemplates.services.Count) services defined in manifest file '$ServiceTemplateFile'"

if ($UsePodIdentity) {
    $serviceTemplates.services | ForEach-Object {
        $serviceName = $_.name
        LogStep -Message "Ensure pod identity for service '$serviceName'"
        $serviceIdentity = EnsureServiceIentity -serviceName $ServiceName -bootstrapValues $bootstrapValues
        LogInfo "MSI for service '$serviceName' is created with client id '$($serviceIdentity.clientId)'"
    }
}


$serviceTemplates.services | ForEach-Object {
    $serviceName = $_.name
    if ((-not ($ServicesToDeploy -contains "all") -and (-not ($ServicesToDeploy -contains $serviceName)))) {
        LogStep -Message "Skipping deploying service '$serviceName'"
    }
    else {
        LogStep -Message "Getting service setting '$serviceName'..."
        $svcOutputFolder = Join-Path $yamlsFolder $serviceName
        if (-not (Test-Path $svcOutputFolder)) {
            New-Item $svcOutputFolder -ItemType Directory -Force | Out-Null
        }

        $serviceSetting = GetServiceSetting `
            -EnvName $EnvName `
            -SpaceName $SpaceName `
            -AzAccount $azAccount `
            -ServiceName $serviceName `
            -templateFolder $templateFolder `
            -scriptFolder $scriptFolder `
            -bootstrapValues $bootstrapValues `
            -UsePodIdentity $UsePodIdentity `
            -BuildNumber $BuildNumber `
            -ServiceTemplateFile $ServiceTemplateFile `
            -IsLocal $IsLocal

        UsingScope("Building service '$serviceName'") {
            & $scriptFolder\BuildService.ps1 `
                -EnvName $EnvName `
                -SpaceName $SpaceName `
                -ServiceTemplateFile $ServiceTemplateFile `
                -ServiceName $serviceName `
                -UsePodIdentity $UsePodIdentity `
                -BuildNumber $BuildNumber `
                -IsLocal $IsLocal
        }


        LogStep -Message "Check image '$($acr.loginServer)/$($serviceSetting.service.image.name)' exists in ACR '$($bootstrapValues.acr.name)'"
        $imagePublished = CheckImageExistance `
            -bootstrapValues $bootstrapValues `
            -ImageName "$($acr.loginServer)/$($serviceSetting.service.image.name)" `
            -ImageTag $BuildNumber
        if ($false -eq $imagePublished) {
            throw "Docker image is not found in acr"
        }

        if (!$IsLocal) {
            UsingScope("Deploying service '$serviceName' to aks") {
                DeployServiceToAks `
                    -serviceSetting $serviceSetting `
                    -TemplateFolder $templateFolder `
                    -ScriptFolder $scriptFolder `
                    -UsePodIdentity $UsePodIdentity `
                    -bootstrapValues $bootstrapValues `
                    -BuildNumber $BuildNumber
            }

            LogStep -Message "Update service reply urls..."
            # UpdateServiceAuthRedirectUrl -ServiceSetting $serviceSetting -BootstrapValues $bootstrapValues

            # if ($bootstrapValues.dns.sslCertSelfSigned -and $serviceSetting.service.type -ne "job") {
            #     # https://github.com/fbeltrao/aks-letsencrypt/blob/master/setup-wildcard-certificates-with-azure-dns.md
            #     LogStep -Message "Setup ssl certificate '$($bootstrapValues.dns.sslCert)' with cert-manager and lets-encrypt..."
            #     $serviceTlsCertYamlTemplateFile = Join-Path $templateFolder "k8s-sslcert-letsencrypt.yaml"
            #     $serviceTlsCertYamlTemplate = Get-Content $serviceTlsCertYamlTemplateFile -Raw
            #     $serviceTlsCertYamlTemplate = Set-YamlValues -ValueTemplate $serviceTlsCertYamlTemplate -Settings $bootstrapValues
            #     $serviceTlsCertYamlTemplate = Set-YamlValues -ValueTemplate $serviceTlsCertYamlTemplate -Settings $serviceSetting
            #     $serviceTlsCertYamlFile = Join-Path $svcOutputFolder "tls-cert.yaml"
            #     $serviceTlsCertYamlTemplate | Out-File $serviceTlsCertYamlFile -Encoding utf8 -Force | Out-Null
            #     kubectl apply -f $serviceTlsCertYamlFile

            #     LogStep -Message "Update ingress annotation to use letsencrypt..."
            #     $serviceIngresTemplateFile = Join-Path $templateFolder "k8s-ingress-letsencrypt.yaml"
            #     $serviceIngresTemplate = Get-Content $serviceIngresTemplateFile -Raw
            #     $serviceIngresTemplate = Set-YamlValues -ValueTemplate $serviceIngresTemplate -Settings $bootstrapValues
            #     $serviceIngresTemplate = Set-YamlValues -ValueTemplate $serviceIngresTemplate -Settings $ServiceSetting
            #     $serviceIngressYamlFile = Join-Path $svcOutputFolder "ingress.yaml"
            #     $serviceIngresTemplate | Out-File $serviceIngressYamlFile -Encoding utf8 -Force | Out-Null
            #     kubectl apply -f $serviceIngressYamlFile
            # }
        }
        else {
            # TODO: move this block to file `Deploy-AppsInDocker.ps1`
            UsingScope("Running service '$serviceName' in docker") {
                docker run -d "$($serviceSetting.acrName).azurecr.io/$($serviceSetting.service.image.name):$($serviceSetting.service.image.tag)"
            }
        }
    }
}
