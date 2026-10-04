// Allow the AKS egress IP through Scenario 2's PostgreSQL firewall.
param serverName string
param ruleName string
param ipAddress string

resource pg 'Microsoft.DBforPostgreSQL/flexibleServers@2024-08-01' existing = {
  name: serverName
}

resource rule 'Microsoft.DBforPostgreSQL/flexibleServers/firewallRules@2024-08-01' = {
  parent: pg
  name: ruleName
  properties: { startIpAddress: ipAddress, endIpAddress: ipAddress }
}
