// Scenario 3 – AKS cluster for the Scenario 1 and Scenario 2 workloads.
// Deploy into its own resource group after Scenario1/infra/main.bicep and
// Scenario2/infra/main.bicep (it reuses their identities, Key Vaults, ACR and databases).
//
//  * Workload identity + OIDC issuer: pods authenticate as the existing managed identities
//    (ordersva-id, ptorag-id, ptorag-pipelines-id) through federated credentials, so no
//    client secrets exist. DefaultAzureCredential in the apps picks this up unchanged.
//  * Secrets Store CSI driver add-on (with rotation): Key Vault secrets and the ingress
//    TLS certificate become Kubernetes Secrets.
//  * Application routing add-on: managed NGINX Ingress controller.
//  * Azure CNI overlay + Cilium: NetworkPolicy enforcement.
//  * Static egress IP: Scenario 2's PostgreSQL firewall and the Databricks-on-AWS IP access
//    list allow exactly one IP (this template adds it to the PostgreSQL firewall).
//  * Entra ID-only cluster access (local accounts disabled, Azure RBAC for Kubernetes).
targetScope = 'resourceGroup'

param location string = resourceGroup().location
param clusterName string = 'ai-platform-aks'
@description('Empty = the region\'s default Kubernetes version.')
param kubernetesVersion string = ''
param nodeVmSize string = 'Standard_D4ds_v5'
param nodeMinCount int = 2
param nodeMaxCount int = 5
@description('Kubernetes namespace the Helm chart is installed into.')
param namespace string = 'ai-platform'

// ---- Scenario 1 (Orders) resources ----
param ordersResourceGroup string = 'rg-orders-va'
param ordersIdentityName string = 'ordersva-id'
@description('ACR from Scenario 1 (acrLoginServer output without .azurecr.io). All images go here.')
param acrName string

// ---- Scenario 2 (PTO) resources ----
param ptoResourceGroup string = 'rg-pto-rag'
param ptoApiIdentityName string = 'ptorag-id'
param ptoPipelinesIdentityName string = 'ptorag-pipelines-id'
@description('PostgreSQL flexible server name from Scenario 2 (the host name before .postgres.database.azure.com).')
param ptoPostgresServerName string

@description('Object ID of the CI/CD service principal (GitHub Actions OIDC). Empty = skip its role assignments.')
param deployerPrincipalId string = ''

var networkContributor = '4d97b98b-1d4f-4787-a291-c67834d212e7'
var aksRbacWriter = 'a7ffa36f-339b-4b5c-8bdf-e2c188b2c0eb'
var aksClusterUser = '4abbcc35-e782-43d8-92c5-2d3f1bd2253f'

// ---------- Egress IP + control plane identity ----------
resource egressIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${clusterName}-egress-ip'
  location: location
  sku: { name: 'Standard' }
  zones: [ '1', '2', '3' ]
  properties: { publicIPAllocationMethod: 'Static' }
}

// A user-assigned control plane identity can be granted rights on the egress IP before the
// cluster exists (a system-assigned one couldn't, and cluster creation would fail).
resource controlPlaneId 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${clusterName}-cp-id'
  location: location
}

resource egressIpRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: egressIp
  name: guid(egressIp.id, controlPlaneId.id, networkContributor)
  properties: {
    principalId: controlPlaneId.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', networkContributor)
  }
}

resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${clusterName}-logs'
  location: location
  properties: { sku: { name: 'PerGB2018' }, retentionInDays: 30 }
}

// ---------- AKS ----------
resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: clusterName
  location: location
  sku: { name: 'Base', tier: 'Standard' }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${controlPlaneId.id}': {} }
  }
  properties: {
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    dnsPrefix: clusterName
    enableRBAC: true
    disableLocalAccounts: true
    aadProfile: { managed: true, enableAzureRBAC: true, tenantID: subscription().tenantId }
    agentPoolProfiles: [ {
      name: 'system'
      mode: 'System'
      vmSize: nodeVmSize
      osType: 'Linux'
      osSKU: 'AzureLinux'
      enableAutoScaling: true
      count: nodeMinCount
      minCount: nodeMinCount
      maxCount: nodeMaxCount
      availabilityZones: [ '1', '2', '3' ]
      upgradeSettings: { maxSurge: '33%' }
    } ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      networkDataplane: 'cilium'
      networkPolicy: 'cilium'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
      loadBalancerProfile: { outboundIPs: { publicIPs: [ { id: egressIp.id } ] } }
    }
    oidcIssuerProfile: { enabled: true }
    securityProfile: {
      workloadIdentity: { enabled: true }
      imageCleaner: { enabled: true, intervalHours: 48 }
    }
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: { enableSecretRotation: 'true', rotationPollInterval: '2m' }
      }
      omsagent: {
        enabled: true
        config: { logAnalyticsWorkspaceResourceID: logs.id }
      }
    }
    ingressProfile: { webAppRouting: { enabled: true } }
    autoUpgradeProfile: { upgradeChannel: 'patch', nodeOSUpgradeChannel: 'NodeImage' }
  }
  dependsOn: [ egressIpRole ]
}

var issuer = aks.properties.oidcIssuerProfile.issuerURL

// ---------- Scenario 1: workload identity, ACR ----------
module ordersFederation 'modules/federation.bicep' = {
  name: 'federation-orders'
  scope: resourceGroup(ordersResourceGroup)
  params: {
    identityName: ordersIdentityName
    issuer: issuer
    credentialName: '${clusterName}-orders-sa'
    subject: 'system:serviceaccount:${namespace}:orders-sa'
  }
}

module acrRoles 'modules/acr-roles.bicep' = {
  name: 'acr-roles'
  scope: resourceGroup(ordersResourceGroup)
  params: {
    acrName: acrName
    kubeletObjectId: aks.properties.identityProfile.kubeletidentity.objectId
    deployerPrincipalId: deployerPrincipalId
  }
}

// ---------- Scenario 2: workload identities, PostgreSQL firewall ----------
module ptoApiFederation 'modules/federation.bicep' = {
  name: 'federation-pto'
  scope: resourceGroup(ptoResourceGroup)
  params: {
    identityName: ptoApiIdentityName
    issuer: issuer
    credentialName: '${clusterName}-pto-sa'
    subject: 'system:serviceaccount:${namespace}:pto-sa'
  }
}

module ptoPipelinesFederation 'modules/federation.bicep' = {
  name: 'federation-pto-pipelines'
  scope: resourceGroup(ptoResourceGroup)
  params: {
    identityName: ptoPipelinesIdentityName
    issuer: issuer
    credentialName: '${clusterName}-pto-pipelines-sa'
    subject: 'system:serviceaccount:${namespace}:pto-pipelines-sa'
  }
}

module pgFirewall 'modules/pg-firewall.bicep' = {
  name: 'pg-firewall-aks'
  scope: resourceGroup(ptoResourceGroup)
  params: {
    serverName: ptoPostgresServerName
    ruleName: '${clusterName}-egress'
    ipAddress: egressIp.properties.ipAddress
  }
}

// ---------- CI/CD deployer: get credentials + deploy into the cluster ----------
resource deployerClusterUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: aks
  name: guid(aks.id, deployerPrincipalId, aksClusterUser)
  properties: {
    principalId: deployerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksClusterUser)
  }
}

// Writer can create/update workloads, Secrets and NetworkPolicies but not RBAC objects or
// namespaces. To narrow it to one namespace, assign it with the CLI instead:
//   az role assignment create --role "Azure Kubernetes Service RBAC Writer" \
//     --assignee-object-id <id> --scope "<cluster id>/namespaces/ai-platform"
resource deployerWriter 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: aks
  name: guid(aks.id, deployerPrincipalId, aksRbacWriter)
  properties: {
    principalId: deployerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', aksRbacWriter)
  }
}

output clusterName string = aks.name
output oidcIssuerUrl string = issuer
output egressIpAddress string = egressIp.properties.ipAddress   // add to the Databricks-on-AWS IP access list
output ordersIdentityClientId string = ordersFederation.outputs.clientId
output ptoIdentityClientId string = ptoApiFederation.outputs.clientId
output ptoPipelinesIdentityClientId string = ptoPipelinesFederation.outputs.clientId
