// Federated credential: lets one Kubernetes ServiceAccount sign in as an existing
// user-assigned managed identity (AKS workload identity). No client secret involved.
param identityName string
param issuer string
param credentialName string
param subject string     // system:serviceaccount:<namespace>:<serviceaccount>

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: identityName
}

resource federated 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: identity
  name: credentialName
  properties: {
    issuer: issuer
    subject: subject
    audiences: [ 'api://AzureADTokenExchange' ]
  }
}

output clientId string = identity.properties.clientId
