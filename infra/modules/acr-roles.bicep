// AcrPull for the AKS kubelet identity; AcrPush for the CI/CD service principal.
param acrName string
param kubeletObjectId string
param deployerPrincipalId string = ''

var acrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538f'
var acrPush = '8311e382-0749-4cb8-b61a-304f252e45ec'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

resource kubeletPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: acr
  name: guid(acr.id, kubeletObjectId, acrPull)
  properties: {
    principalId: kubeletObjectId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPull)
  }
}

resource deployerPush 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(deployerPrincipalId)) {
  scope: acr
  name: guid(acr.id, deployerPrincipalId, acrPush)
  properties: {
    principalId: deployerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPush)
  }
}
