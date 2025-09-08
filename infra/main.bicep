// ========== main.bicep ========== //
targetScope = 'resourceGroup'

metadata name = 'Document Generation Solution Accelerator'
metadata description = '''CSA CTO Gold Standard Solution Accelerator for Document Generation.
'''

@minLength(3)
@maxLength(15)
@description('Optional. A unique application/solution name for all resources in this deployment. This should be 3-15 characters long.')
param solutionName string = 'docgen'

@maxLength(5)
@description('Optional. A unique text value for the solution. This is used to ensure resource names are unique for global resources. Defaults to a 5-character substring of the unique string generated from the subscription ID, resource group name, and solution name.')
param solutionUniqueText string = substring(uniqueString(subscription().id, resourceGroup().name, solutionName), 0, 5)

@description('Optional. Azure location for the solution. If not provided, it defaults to the resource group location.')
param location string = ''

@minLength(3)
@description('Optional. Secondary location for databases creation(example:eastus2):')
param secondaryLocation string = 'eastus2'

@allowed([
  'australiaeast'
  'eastus'
  'eastus2'
  'francecentral'
  'japaneast'
  'koreacentral'
  'swedencentral'
  'switzerlandnorth'
  'uaenorth'
  'uksouth'
  'westus'
  'westus3'
])
@description('Location for AI deployments. This should be a valid Azure region where OpenAI services are available.')
@metadata({
  azd: {
    type: 'location'
    usageName: [
      'OpenAI.GlobalStandard.gpt4.1, 150'
      'OpenAI.GlobalStandard.text-embedding-ada-002, 80'
    ]
  }
})
param aiDeploymentsLocation string

@minLength(1)
@allowed([
  'Standard'
  'GlobalStandard'
])
@description('Optional. GPT model deployment type. Defaults to GlobalStandard.')
param gptModelDeploymentType string = 'GlobalStandard'

@minLength(1)
@description('Optional. Name of the GPT model to deploy.')
param gptModelName string = 'gpt-4.1'

@description('Optional. Version of the GPT model to deploy. Defaults to 2025-04-14.')
param gptModelVersion string = '2025-04-14'

@description('Optional. API version for Azure OpenAI service. This should be a valid API version supported by the service.')
param azureOpenaiAPIVersion string = '2025-01-01-preview'

@description('Optional. API version for Azure AI Agent service. This should be a valid API version supported by the service.')
param azureAiAgentApiVersion string = '2025-05-01'

@minValue(10)
@description('Optional. AI model deployment token capacity. Defaults to 150 for optimal performance.')
param gptModelCapacity int = 150

@minLength(1)
@description('Optional. Name of the Text Embedding model to deploy:')
param embeddingModel string = 'text-embedding-ada-002'

@minValue(10)
@description('Optional. Capacity of the Embedding Model deployment')
param embeddingDeploymentCapacity int = 80

@description('Optional. Existing Log Analytics Workspace Resource ID')
param existingLogAnalyticsWorkspaceId string = ''

@description('Optional. Resource ID of an existing Foundry project')
param azureExistingAIProjectResourceId string = ''

@description('Optional. Size of the Jumpbox Virtual Machine when created. Set to custom value if enablePrivateNetworking is true.')
param vmSize string? 

@description('Optional. Admin username for the Jumpbox Virtual Machine. Set to custom value if enablePrivateNetworking is true.')
@secure()
param vmAdminUsername string?

@description('Optional. Admin password for the Jumpbox Virtual Machine. Set to custom value if enablePrivateNetworking is true.')
@secure()
param vmAdminPassword string?

@description('Optional. The tags to apply to all deployed Azure resources.')
param tags resourceInput<'Microsoft.Resources/resourceGroups@2025-04-01'>.tags = {}

@description('Optional. Enable monitoring applicable resources, aligned with the Well Architected Framework recommendations. This setting enables Application Insights and Log Analytics and configures all the resources applicable resources to send logs. Defaults to false.')
param enableMonitoring bool = false

@description('Optional. Enable scalability for applicable resources, aligned with the Well Architected Framework recommendations. Defaults to false.')
param enableScalability bool = false

@description('Optional. Enable redundancy for applicable resources, aligned with the Well Architected Framework recommendations. Defaults to false.')
param enableRedundancy bool = false

@description('Optional. Enable private networking for applicable resources, aligned with the Well Architected Framework recommendations. Defaults to false.')
param enablePrivateNetworking bool = false

@description('Optional. The Container Registry hostname where the docker images are located.')
param acrName string = 'testapwaf'  // byocgacontainerreg

@description('Optional. Image Tag.')
param imageTag string = 'waf'

@description('Optional. Enable/Disable usage telemetry for module.')
param enableTelemetry bool = true

@description('Optional. Enable purge protection for the Key Vault')
param enablePurgeProtection bool = false

// ============== //
// Variables      //
// ============== //

var solutionLocation = empty(location) ? resourceGroup().location : location
var solutionSuffix = toLower(trim(replace(
  replace(
    replace(replace(replace(replace('${solutionName}${solutionUniqueText}', '-', ''), '_', ''), '.', ''), '/', ''),
    ' ',
    ''
  ),
  '*',
  ''
)))

@description('Optional. The tags to apply to all deployed Azure resources.')
param tags resourceInput<'Microsoft.Resources/resourceGroups@2025-04-01'>.tags = {}

@description('Optional created by user name')
param createdBy string = empty(deployer().userPrincipalName) ? '' : split(deployer().userPrincipalName, '@')[0]
// ========== Resource Group Tag ========== //
resource resourceGroupTags 'Microsoft.Resources/tags@2021-04-01' = {
  name: 'default'
  properties: {
    tags: {
      ... tags
      TemplateName: 'Docgen'
      CreatedBy: createdBy
    }
  }
}

// Extracts subscription, resource group, and workspace name from the resource ID when using an existing Log Analytics workspace
var useExistingLogAnalytics = !empty(existingLogAnalyticsWorkspaceId)

// ========== Log Analytics Workspace ========== //
var logAnalyticsWorkspaceResourceName = 'log-${solutionSuffix}'
module logAnalyticsWorkspace 'br/public:avm/res/operational-insights/workspace:0.12.0' = if (enableMonitoring && !useExistingLogAnalytics) {
  name: take('avm.res.operational-insights.workspace.${logAnalyticsWorkspaceResourceName}', 64)
  params: {
    name: logAnalyticsWorkspaceResourceName
    tags: tags
    location: solutionLocation
    enableTelemetry: enableTelemetry
    skuName: 'PerGB2018'
    dataRetention: 365
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
    diagnosticSettings: [{ useThisWorkspace: true }]
    // WAF aligned configuration for Redundancy
    dailyQuotaGb: enableRedundancy ? 10 : null //WAF recommendation: 10 GB per day is a good starting point for most workloads
    replication: enableRedundancy
      ? {
          enabled: true
          location: replicaLocation
        }
      : null
    // WAF aligned configuration for Private Networking
    publicNetworkAccessForIngestion: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    publicNetworkAccessForQuery: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    dataSources: enablePrivateNetworking
      ? [
          {
            tags: tags
            eventLogName: 'Application'
            eventTypes: [
              {
                eventType: 'Error'
              }
              {
                eventType: 'Warning'
              }
              {
                eventType: 'Information'
              }
            ]
            kind: 'WindowsEvent'
            name: 'applicationEvent'
          }
          {
            counterName: '% Processor Time'
            instanceName: '*'
            intervalSeconds: 60
            kind: 'WindowsPerformanceCounter'
            name: 'windowsPerfCounter1'
            objectName: 'Processor'
          }
          {
            kind: 'IISLogs'
            name: 'sampleIISLog1'
            state: 'OnPremiseEnabled'
          }
        ]
      : null
  }
}
var logAnalyticsWorkspaceResourceId = useExistingLogAnalytics ? existingLogAnalyticsWorkspaceId : logAnalyticsWorkspace!.outputs.resourceId
// ========== Application Insights ========== //
var applicationInsightsResourceName = 'appi-${solutionSuffix}'
module applicationInsights 'br/public:avm/res/insights/component:0.6.0' = if (enableMonitoring && !useExistingLogAnalytics) {
  name: take('avm.res.insights.component.${applicationInsightsResourceName}', 64)
  params: {
    name: applicationInsightsResourceName
    tags: tags
    location: solutionLocation
    enableTelemetry: enableTelemetry
    retentionInDays: 365
    kind: 'web'
    disableIpMasking: false
    flowType: 'Bluefield'
    // WAF aligned configuration for Monitoring
    workspaceResourceId: enableMonitoring ? logAnalyticsWorkspaceResourceId : ''
    diagnosticSettings: enableMonitoring ? [{ workspaceResourceId: logAnalyticsWorkspaceResourceId }] : null
  }
}

// ========== User Assigned Identity ========== //
var userAssignedIdentityResourceName = 'id-${solutionSuffix}'
module userAssignedIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.4.1' = {
  name: take('avm.res.managed-identity.user-assigned-identity.${userAssignedIdentityResourceName}', 64)
  params: {
    name: userAssignedIdentityResourceName
    location: solutionLocation
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// ========== Managed Identity ========== //
// module managedIdentityModule 'modules/deploy_managed_identity.bicep' = {
//   name: 'deploy_managed_identity'
//   params: {
//     solutionName: solutionSuffix
//     solutionLocation: solutionLocation
//     miName: 'id-${solutionSuffix}'
//     tags : tags
//   }
//   scope: resourceGroup(resourceGroup().name)
// }
// ========== Network Module ========== //
module network 'modules/network.bicep' = if (enablePrivateNetworking) {
  name: take('module.network.${solutionSuffix}', 64)
  params: {
    resourcesName: solutionSuffix
    logAnalyticsWorkSpaceResourceId: logAnalyticsWorkspaceResourceId
    vmAdminUsername: vmAdminUsername ?? 'JumpboxAdminUser'
    vmAdminPassword: vmAdminPassword ?? 'JumpboxAdminP@ssw0rd1234!'
    vmSize: vmSize ??  'Standard_DS2_v2' // Default VM size 
    location: solutionLocation
    tags: tags
    enableTelemetry: enableTelemetry
  }
}

// ========== Private DNS Zones ========== //
var privateDnsZones = [
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.services.ai.azure.com'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink.queue.${environment().suffixes.storage}'
  'privatelink.documents.azure.com'
  'privatelink.vaultcore.azure.net'
  'privatelink.azurewebsites.net'
  'privatelink.search.windows.net'
]
 
// DNS Zone Index Constants
var dnsZoneIndex = {
  cognitiveServices: 0
  openAI: 1
  aiServices: 2
  storageBlob: 3
  storageQueue: 4
  cosmosDB: 5
  keyVault: 6
  appService: 7
  searchService: 8
}

// ===================================================
// DEPLOY PRIVATE DNS ZONES
// - Deploys all zones if no existing Foundry project is used
// - Excludes AI-related zones when using with an existing Foundry project
// ===================================================
@batchSize(5)
module avmPrivateDnsZones 'br/public:avm/res/network/private-dns-zone:0.7.1' = [
  for (zone, i) in privateDnsZones: if (enablePrivateNetworking) {
    name: 'avm.res.network.private-dns-zone.${contains(zone, 'azurecontainerapps.io') ? 'containerappenv' : split(zone, '.')[1]}'
    params: {
      name: zone
      tags: tags
      enableTelemetry: enableTelemetry
      virtualNetworkLinks: [
        {
          name: take('vnetlink-${network!.outputs.vnetName}-${split(zone, '.')[1]}', 80)
          virtualNetworkResourceId: network!.outputs.vnetResourceId
        }
      ]
    }
  }
]

// ==========Key Vault Module ========== //
// module kvault 'modules/deploy_keyvault.bicep' = {
//   name: 'deploy_keyvault'
//   params: {
//     solutionName: solutionSuffix
//     solutionLocation: location
//     managedIdentityObjectId: userAssignedIdentity.outputs.principalId
//     keyvaultName: 'kv-${solutionSuffix}'
//     tags : tags
//   }
//   scope: resourceGroup(resourceGroup().name)
// }

// ==========Key Vault Module ========== //
var keyVaultName = 'kv-${solutionSuffix}'
module keyvault 'br/public:avm/res/key-vault/vault:0.12.1' = {
  name: take('avm.res.key-vault.vault.${keyVaultName}', 64)
  params: {
    name: keyVaultName
    location: solutionLocation
    tags: tags
    sku: 'standard'
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
    }
    enableVaultForDeployment: true
    enableVaultForDiskEncryption: true
    enableVaultForTemplateDeployment: true
    enableRbacAuthorization: true
    enableSoftDelete: true
    enablePurgeProtection: enablePurgeProtection
    softDeleteRetentionInDays: 7
    diagnosticSettings: enableMonitoring 
      ? [{ workspaceResourceId: logAnalyticsWorkspaceResourceId }] 
      : []
    // WAF aligned configuration for Private Networking
    privateEndpoints: enablePrivateNetworking
      ? [
          {
            name: 'pep-${keyVaultName}'
            customNetworkInterfaceName: 'nic-${keyVaultName}'
            privateDnsZoneGroup: {
              privateDnsZoneGroupConfigs: [
                { privateDnsZoneResourceId: avmPrivateDnsZones[dnsZoneIndex.keyVault]!.outputs.resourceId }
              ]
            }
            service: 'vault'
            subnetResourceId: network!.outputs.subnetPrivateEndpointsResourceId
          }
        ]
      : []
    // WAF aligned configuration for Role-based Access Control
    roleAssignments: [
      {
         principalId: userAssignedIdentity.outputs.principalId
         principalType: 'ServicePrincipal'
         roleDefinitionIdOrName: 'Key Vault Administrator'
      }
    ]
    enableTelemetry: enableTelemetry
  }
  dependsOn:[
    avmPrivateDnsZones
  ]
}

// ==========AI Foundry and related resources ========== //
// module aifoundry 'modules/deploy_ai_foundry.bicep' = {
//   name: 'deploy_ai_foundry'
//   params: {
//     solutionName: solutionSuffix
//     solutionLocation: aiDeploymentsLocation
//     keyVaultName: keyvault.outputs.name
//     deploymentType: gptModelDeploymentType
//     gptModelName: gptModelName
//     gptModelVersion: gptModelVersion
//     azureOpenaiAPIVersion: azureOpenaiAPIVersion
//     gptDeploymentCapacity: gptModelCapacity
//     embeddingModel: embeddingModel
//     embeddingDeploymentCapacity: embeddingDeploymentCapacity
//     managedIdentityObjectId: userAssignedIdentity.outputs.principalId
//     existingLogAnalyticsWorkspaceId: existingLogAnalyticsWorkspaceId
//     azureExistingAIProjectResourceId: azureExistingAIProjectResourceId
//     tags : tags
//   }
//   scope: resourceGroup(resourceGroup().name)
// }

// ========== AI Foundry: AI Services ========== //
var useExistingAiFoundryAiProject = !empty(azureExistingAIProjectResourceId)
var aiFoundryAiServicesResourceGroupName = useExistingAiFoundryAiProject
  ? split(azureExistingAIProjectResourceId, '/')[4]
  : 'rg-${solutionSuffix}'
var aiFoundryAiServicesSubscriptionId = useExistingAiFoundryAiProject
  ? split(azureExistingAIProjectResourceId, '/')[2]
  : subscription().id
var aiFoundryAiServicesResourceName = useExistingAiFoundryAiProject
  ? split(azureExistingAIProjectResourceId, '/')[8]
  : 'aif-${solutionSuffix}'
var aiFoundryAiProjectResourceName = useExistingAiFoundryAiProject
  ? split(azureExistingAIProjectResourceId, '/')[10]
  : 'proj-${solutionSuffix}' // AI Project resource id: /subscriptions/<subscription-id>/resourceGroups/<resource-group-name>/providers/Microsoft.CognitiveServices/accounts/<ai-services-name>/projects/<project-name>
var aiFoundryAiServicesModelDeployment = [
  {
    format: 'OpenAI'
    name: gptModelName
    model: gptModelName
    sku: {
      name: gptModelDeploymentType
      capacity: gptModelCapacity
    }
    version: gptModelVersion
    raiPolicyName: 'Microsoft.Default'
  }
  {
    format: 'OpenAI'
    name: embeddingModel
    model: embeddingModel
    sku: {
      name: 'GlobalStandard'
      capacity: embeddingDeploymentCapacity
    }
    version: '2'
    raiPolicyName: 'Microsoft.Default'
  }
]
var aiFoundryAiProjectDescription = 'AI Foundry Project'

resource existingAiFoundryAiServices 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = if (useExistingAiFoundryAiProject) {
  name: aiFoundryAiServicesResourceName
  scope: resourceGroup(aiFoundryAiServicesSubscriptionId, aiFoundryAiServicesResourceGroupName)
}

module existingAiFoundryAiServicesDeployments 'modules/ai-services-deployments.bicep' = if (useExistingAiFoundryAiProject) {
  name: take('module.ai-services-model-deployments.${existingAiFoundryAiServices.name}', 64)
  scope: resourceGroup(aiFoundryAiServicesSubscriptionId, aiFoundryAiServicesResourceGroupName)
  params: {
    name: existingAiFoundryAiServices.name
    deployments: [
      for deployment in aiFoundryAiServicesModelDeployment: {
        name: deployment.name
        model: {
          format: deployment.format
          name: deployment.name
          version: deployment.version
        }
        raiPolicyName: deployment.raiPolicyName
        sku: {
          name: deployment.sku.name
          capacity: deployment.sku.capacity
        }
      }
    ]
    roleAssignments: [
      {
        roleDefinitionIdOrName: '53ca6127-db72-4b80-b1b0-d745d6d5456d' // Azure AI User
        principalId: userAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: '64702f94-c441-49e6-a78b-ef80e0188fee' // Azure AI Developer
        principalId: userAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User
        principalId: userAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
    ]
  }
}

module aiFoundryAiServices 'br:mcr.microsoft.com/bicep/avm/res/cognitive-services/account:0.13.2' = if (!useExistingAiFoundryAiProject) {
  name: take('avm.res.cognitive-services.account.${aiFoundryAiServicesResourceName}', 64)
  params: {
    name: aiFoundryAiServicesResourceName
    location: aiDeploymentsLocation
    tags: tags
    sku: 'S0'
    kind: 'AIServices'
    disableLocalAuth: true
    allowProjectManagement: true
    customSubDomainName: aiFoundryAiServicesResourceName
    apiProperties: {
      //staticsEnabled: false
    }
    deployments: [
      for deployment in aiFoundryAiServicesModelDeployment: {
        name: deployment.name
        model: {
          format: deployment.format
          name: deployment.name
          version: deployment.version
        }
        raiPolicyName: deployment.raiPolicyName
        sku: {
          name: deployment.sku.name
          capacity: deployment.sku.capacity
        }
      }
    ]
    networkAcls: {
      defaultAction: 'Allow'
      virtualNetworkRules: []
      ipRules: []
    }
    managedIdentities: { 
      userAssignedResourceIds: [userAssignedIdentity!.outputs.resourceId] 
    } //To create accounts or projects, you must enable a managed identity on your resource
    roleAssignments: [
      {
        roleDefinitionIdOrName: '53ca6127-db72-4b80-b1b0-d745d6d5456d' // Azure AI User
        principalId: userAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: '64702f94-c441-49e6-a78b-ef80e0188fee' // Azure AI Developer
        principalId: userAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User
        principalId: userAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
    ]
    // WAF aligned configuration for Monitoring
    diagnosticSettings: enableMonitoring ? [{ workspaceResourceId: logAnalyticsWorkspaceResourceId }] : null
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    privateEndpoints: (enablePrivateNetworking)
      ? ([
          {
            name: 'pep-${aiFoundryAiServicesResourceName}'
            customNetworkInterfaceName: 'nic-${aiFoundryAiServicesResourceName}'
            subnetResourceId: network!.outputs.subnetPrivateEndpointsResourceId
            privateDnsZoneGroup: {
              privateDnsZoneGroupConfigs: [
                {
                  name: 'ai-services-dns-zone-cognitiveservices'
                  privateDnsZoneResourceId: avmPrivateDnsZones[dnsZoneIndex.cognitiveServices]!.outputs.resourceId
                }
                {
                  name: 'ai-services-dns-zone-openai'
                  privateDnsZoneResourceId: avmPrivateDnsZones[dnsZoneIndex.openAI]!.outputs.resourceId
                }
                {
                  name: 'ai-services-dns-zone-aiservices'
                  privateDnsZoneResourceId: avmPrivateDnsZones[dnsZoneIndex.aiServices]!.outputs.resourceId
                }
              ]
            }
          }
        ])
      : []
  }
}

resource existingAiFoundryAiServicesProject 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = if (useExistingAiFoundryAiProject) {
  name: aiFoundryAiProjectResourceName
  parent: existingAiFoundryAiServices
}

module aiFoundryAiServicesProject 'modules/ai-project.bicep' = if (!useExistingAiFoundryAiProject) {
  name: take('module.ai-project.${aiFoundryAiProjectResourceName}', 64)
  params: {
    name: aiFoundryAiProjectResourceName
    location: aiDeploymentsLocation
    tags: tags
    desc: aiFoundryAiProjectDescription
    //Implicit dependencies below
    aiServicesName: aiFoundryAiServicesResourceName
    azureExistingAIProjectResourceId: azureExistingAIProjectResourceId
  }
  dependsOn: [
    aiFoundryAiServices
  ]
}

var aiFoundryAiProjectEndpoint = useExistingAiFoundryAiProject
  ? existingAiFoundryAiServicesProject!.properties.endpoints['AI Foundry API']
  : aiFoundryAiServicesProject!.outputs.apiEndpoint

// ========== Search Service to AI Services Role Assignment ========== //
resource searchServiceToAiServicesRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!useExistingAiFoundryAiProject) {
  name: guid(aiSearchName, '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd', aiFoundryAiServicesResourceName)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd') // Cognitive Services OpenAI User
    principalId: aiSearch.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
  }
}

// Role assignment for existing AI Services scenario
module searchServiceToExistingAiServicesRoleAssignment 'modules/role-assignment.bicep' = if (useExistingAiFoundryAiProject) {
  name: 'searchToExistingAiServices-roleAssignment'
  scope: resourceGroup(aiFoundryAiServicesSubscriptionId, aiFoundryAiServicesResourceGroupName)
  params: {
    principalId: aiSearch.outputs.systemAssignedMIPrincipalId!
    roleDefinitionId: '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd' // Cognitive Services OpenAI User
    targetResourceName: existingAiFoundryAiServices.name
  }
}

// ========== AI Foundry: AI Search ========== //
var aiSearchName = 'srch-${solutionSuffix}'
var aiSearchConnectionName = 'foundry-search-connection-${solutionSuffix}'
var nenablePrivateNetworking = false
module aiSearch 'br/public:avm/res/search/search-service:0.11.1' = {
  name: take('avm.res.cognitive-search-services.${aiSearchName}', 64)
  params: {
    name: aiSearchName
    authOptions: {
      aadOrApiKey: {
        aadAuthFailureMode: 'http401WithBearerChallenge'
      }
    }
    tags: tags
    diagnosticSettings: enableMonitoring ? [{ workspaceResourceId: logAnalyticsWorkspaceResourceId }] : null
    disableLocalAuth: false
    hostingMode: 'default'
    sku: enableScalability ? 'standard' : 'basic'
    managedIdentities: { systemAssigned: true }
    networkRuleSet: {
      bypass: 'AzureServices'
      ipRules: []
    }
    replicaCount: 1
    partitionCount: 1
    roleAssignments: [
      {
        roleDefinitionIdOrName: '1407120a-92aa-4202-b7e9-c0e197c71c8f' // Search Index Data Reader
        principalId: userAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: '7ca78c08-252a-4471-8644-bb5ff32d4ba0' // Search Service Contributor
        principalId: userAssignedIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: '1407120a-92aa-4202-b7e9-c0e197c71c8f' // Search Index Data Reader
        principalId: !useExistingAiFoundryAiProject ? aiFoundryAiServicesProject!.outputs.systemAssignedMIPrincipalId : existingAiFoundryAiServicesProject!.identity.principalId
        principalType: 'ServicePrincipal'
      }
      {
        roleDefinitionIdOrName: '7ca78c08-252a-4471-8644-bb5ff32d4ba0' // Search Service Contributor
        principalId: !useExistingAiFoundryAiProject ? aiFoundryAiServicesProject!.outputs.systemAssignedMIPrincipalId : existingAiFoundryAiServicesProject!.identity.principalId
        principalType: 'ServicePrincipal'
      }
    ]
    semanticSearch: 'free'
    // WAF aligned configuration for Private Networking
    publicNetworkAccess: nenablePrivateNetworking ? 'Disabled' : 'Enabled'
    privateEndpoints: nenablePrivateNetworking
    ? [
        {
          name: 'pep-${aiSearchName}'
          customNetworkInterfaceName: 'nic-${aiSearchName}'
          privateDnsZoneGroup: {
            privateDnsZoneGroupConfigs: [
              { privateDnsZoneResourceId: avmPrivateDnsZones[dnsZoneIndex.searchService]!.outputs.resourceId }
            ]
          }
          subnetResourceId: network!.outputs.subnetPrivateEndpointsResourceId
          service: 'searchService'
        }
      ]
    : []
  }
}

resource aiSearchFoundryConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!useExistingAiFoundryAiProject) {
  name: '${aiFoundryAiServicesResourceName}/${aiFoundryAiProjectResourceName}/${aiSearchConnectionName}'
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${aiSearchName}.search.windows.net'
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: aiSearch.outputs.resourceId
      location: aiSearch.outputs.location
    }
  }
}

module existing_AIProject_SearchConnectionModule 'modules/deploy_aifp_aisearch_connection.bicep' = if (useExistingAiFoundryAiProject) {
  name: 'aiProjectSearchConnectionDeployment'
  scope: resourceGroup(aiFoundryAiServicesSubscriptionId, aiFoundryAiServicesResourceGroupName)
  params: {
    existingAIProjectName: aiFoundryAiProjectResourceName
    existingAIFoundryName: aiFoundryAiServicesResourceName
    aiSearchName: aiSearchName
    aiSearchResourceId: aiSearch.outputs.resourceId
    aiSearchLocation: aiSearch.outputs.location
    aiSearchConnectionName: aiSearchConnectionName
  }
}

// ========== Storage account module ========== //
// module storageAccount 'modules/deploy_storage_account.bicep' = {
//   name: 'deploy_storage_account'
//   params: {
//     solutionName: solutionSuffix
//     solutionLocation: location
//     keyVaultName: keyvault.outputs.name
//     managedIdentityObjectId: userAssignedIdentity.outputs.principalId
//     saName: 'st${solutionSuffix}'
//     tags : tags
//   }
//   scope: resourceGroup(resourceGroup().name)
// }

var storageAccountName = 'st${solutionSuffix}'
module storageAccount 'br/public:avm/res/storage/storage-account:0.20.0' = {
  name: take('avm.res.storage.storage-account.${storageAccountName}', 64)
  params: {
    name: storageAccountName
    location: solutionLocation
    skuName: 'Standard_LRS'
    managedIdentities: { systemAssigned: true }
    minimumTlsVersion: 'TLS1_2'
    enableTelemetry: enableTelemetry
    tags: tags
    accessTier: 'Hot'
    supportsHttpsTrafficOnly: true
    blobServices: {
      containerDeleteRetentionPolicyEnabled: false
      containerDeleteRetentionPolicyDays: 7
      deleteRetentionPolicyEnabled: false
      deleteRetentionPolicyDays: 6
      containers: [
        {
          name: 'data'
          publicAccess: 'None'
          denyEncryptionScopeOverride: false
          defaultEncryptionScope: '$account-encryption-key'
        }
      ]
    }
    roleAssignments: [
      {
        principalId: userAssignedIdentity.outputs.principalId
        roleDefinitionIdOrName: 'Storage Blob Data Contributor'
        principalType: 'ServicePrincipal'
      }
    ]
    // WAF aligned networking
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: enablePrivateNetworking ? 'Deny' : 'Allow'
    }
    allowBlobPublicAccess: enablePrivateNetworking ? true : false
    publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    // Private endpoints for blob and queue
    privateEndpoints: enablePrivateNetworking
      ? [
          {
            name: 'pep-blob-${solutionSuffix}'
            privateDnsZoneGroup: {
              privateDnsZoneGroupConfigs: [
                {
                  name: 'storage-dns-zone-group-blob'
                  privateDnsZoneResourceId: avmPrivateDnsZones[dnsZoneIndex.storageBlob]!.outputs.resourceId
                }
              ]
            }
            subnetResourceId: network!.outputs.subnetPrivateEndpointsResourceId
            service: 'blob'
          }
          {
            name: 'pep-queue-${solutionSuffix}'
            privateDnsZoneGroup: {
              privateDnsZoneGroupConfigs: [
                {
                  name: 'storage-dns-zone-group-queue'
                  privateDnsZoneResourceId: avmPrivateDnsZones[dnsZoneIndex.storageQueue]!.outputs.resourceId
                }
              ]
            }
            subnetResourceId: network!.outputs.subnetPrivateEndpointsResourceId
            service: 'queue'
          }
        ]
      : []
  }
  scope: resourceGroup(resourceGroup().name)
}

//========== Updates to Key Vault ========== //
// resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
//   name: aifoundry.outputs.keyvaultName
//   scope: resourceGroup(resourceGroup().name)
// }

// ========== Cosmos DB module ========== //
// module cosmosDBModule 'modules/deploy_cosmos_db.bicep' = {
//   name: 'deploy_cosmos_db'
//   params: {
//     // solutionName: solutionSuffix
//     solutionLocation: secondaryLocation
//     keyVaultName: keyvault.outputs.name
//     accountName: 'cosmos-${solutionSuffix}'
//     tags : tags
//   }
//   scope: resourceGroup(resourceGroup().name)
// }
var cosmosDBResourceName = 'cosmos-${solutionSuffix}'
var cosmosDBDatabaseName = 'db_conversation_history'
var cosmosDBcollectionName = 'conversations'

module cosmosDB 'br/public:avm/res/document-db/database-account:0.15.0' = {
  name: take('avm.res.document-db.database-account.${cosmosDBResourceName}', 64)
  params: {
    // Required parameters
    name: 'cosmos-${solutionSuffix}'
    location: secondaryLocation
    tags: tags
    enableTelemetry: enableTelemetry
    sqlDatabases: [
      {
        name: cosmosDBDatabaseName
        containers: [
          {
            name: cosmosDBcollectionName
            paths: [
              '/userId'
            ]
          }
        ]
      }
    ]
    dataPlaneRoleDefinitions: [
      {
        // Cosmos DB Built-in Data Contributor: https://docs.azure.cn/en-us/cosmos-db/nosql/security/reference-data-plane-roles#cosmos-db-built-in-data-contributor
        roleName: 'Cosmos DB SQL Data Contributor'
        dataActions: [
          'Microsoft.DocumentDB/databaseAccounts/readMetadata'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/*'
          'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers/items/*'
        ]
        assignments: [{ principalId: userAssignedIdentity.outputs.principalId }]
      }
    ]
    // WAF aligned configuration for Monitoring
    diagnosticSettings: enableMonitoring ? [{ workspaceResourceId: logAnalyticsWorkspaceResourceId }] : null
    // WAF aligned configuration for Private Networking
    networkRestrictions: {
      networkAclBypass: 'None'
      publicNetworkAccess: enablePrivateNetworking ? 'Disabled' : 'Enabled'
    }
    privateEndpoints: enablePrivateNetworking
      ? [
          {
            name: 'pep-${cosmosDBResourceName}'
            customNetworkInterfaceName: 'nic-${cosmosDBResourceName}'
            privateDnsZoneGroup: {
              privateDnsZoneGroupConfigs: [
                { privateDnsZoneResourceId: avmPrivateDnsZones[dnsZoneIndex.cosmosDB]!.outputs.resourceId }
              ]
            }
            service: 'Sql'
            subnetResourceId: network!.outputs.subnetPrivateEndpointsResourceId
          }
        ]
      : []
    // WAF aligned configuration for Redundancy
    zoneRedundant: enableRedundancy ? true : false
    capabilitiesToAdd: enableRedundancy ? null : ['EnableServerless']
    automaticFailover: enableRedundancy ? true : false
    failoverLocations: enableRedundancy
      ? [
          {
            failoverPriority: 0
            isZoneRedundant: true
            locationName: solutionLocation
          }
          {
            failoverPriority: 1
            isZoneRedundant: true
            locationName: cosmosDbHaLocation
          }
        ]
      : [
          {
            locationName: solutionLocation
            failoverPriority: 0
          }
        ]
  }
  scope: resourceGroup(resourceGroup().name)
}

// working version of saving storage account secrets in key vault using AVM module
module saveSecretsInKeyVault 'br/public:avm/res/key-vault/vault:0.12.1' = {
  name: take('saveSecretsInKeyVault.${keyVaultName}', 64)
  params: {
    name: keyVaultName
    enableVaultForDeployment: true
    enableVaultForDiskEncryption: true
    enableVaultForTemplateDeployment: true
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    secrets: [
      {
        name: 'ADLS-ACCOUNT-NAME'
        value: storageAccountName
      }
      {
        name: 'ADLS-ACCOUNT-CONTAINER'
        value: 'data'
      }
      {
        name: 'ADLS-ACCOUNT-KEY'
        value: storageAccount.outputs.primaryAccessKey
      }
      {
        name: 'AZURE-COSMOSDB-ACCOUNT'
        value: cosmosDB.outputs.name
      }
      {
        name: 'AZURE-COSMOSDB-ACCOUNT-KEY'
        value: cosmosDB.outputs.primaryReadWriteKey
      }
      {
        name: 'AZURE-COSMOSDB-DATABASE'
        value: cosmosDBDatabaseName
      }
      {
        name: 'AZURE-COSMOSDB-CONVERSATIONS-CONTAINER'
        value: cosmosDBcollectionName
      }
      {
        name: 'AZURE-COSMOSDB-ENABLE-FEEDBACK'
        value: 'True'
      }
      {name: 'AZURE-LOCATION', value: aiDeploymentsLocation}
      {name: 'AZURE-RESOURCE-GROUP', value: resourceGroup().name}
      {name: 'AZURE-SUBSCRIPTION-ID', value: subscription().subscriptionId}
      {
        name: 'COG-SERVICES-NAME'
        value: aiFoundryAiServicesResourceName
      }
      // {
      //   name: 'COG-SERVICES-KEY'
      //   value: !useExistingAiFoundryAiProject ? existingAiFoundryAiServices!.listKeys().key1 : aiFoundryAiServices!.listKeys().key1
      // }
      {
        name: 'COG-SERVICES-ENDPOINT'
        value: 'https://${aiFoundryAiServicesResourceName}.openai.azure.com/'
      }
      {name: 'AZURE-SEARCH-INDEX', value: 'pdf_index'}
      {
        name: 'AZURE-SEARCH-SERVICE'
        value: aiSearch.outputs.name
      }
      {
        name: 'AZURE-SEARCH-ENDPOINT'
        value: 'https://${aiSearch.outputs.name}.search.windows.net'
      }
      {name: 'AZURE-OPENAI-EMBEDDING-MODEL', value: embeddingModel}
      {
        name: 'AZURE-OPENAI-ENDPOINT'
        value: 'https://${aiFoundryAiServicesResourceName}.openai.azure.com/'
      }
      {name: 'AZURE-OPENAI-PREVIEW-API-VERSION', value: azureOpenaiAPIVersion}
      {name: 'AZURE-OPEN-AI-DEPLOYMENT-MODEL', value: gptModelName}
      {name: 'TENANT-ID', value: subscription().tenantId}
    ]
  }
}

//========== App service module ========== //
// module appserviceModule 'modules/deploy_app_service.bicep' = {
//   name: 'deploy_app_service'
//   params: {
//     imageTag: imageTag
//     applicationInsightsId: aifoundry.outputs.applicationInsightsId
//     // identity:managedIdentityModule.outputs.managedIdentityOutput.id
//     solutionName: solutionSuffix
//     solutionLocation: location
//     aiSearchService: aifoundry.outputs.aiSearchService
//     aiSearchName: aifoundry.outputs.aiSearchName
//     azureAiAgentApiVersion: azureAiAgentApiVersion
//     azureOpenAIEndpoint: aifoundry.outputs.aoaiEndpoint
//     azureOpenAIModel: gptModelName
//     azureOpenAIApiVersion: azureOpenaiAPIVersion //'2024-02-15-preview'
//     azureOpenaiResource: aifoundry.outputs.aiFoundryName
//     aiFoundryProjectName: aifoundry.outputs.aiFoundryProjectName
//     aiFoundryName: aifoundry.outputs.aiFoundryName
//     aiFoundryProjectEndpoint: aifoundry.outputs.aiFoundryProjectEndpoint
//     USE_CHAT_HISTORY_ENABLED: 'True'
//     AZURE_COSMOSDB_ACCOUNT: cosmosDB.outputs.name
//     // AZURE_COSMOSDB_ACCOUNT_KEY: keyVault.getSecret('AZURE-COSMOSDB-ACCOUNT-KEY')
//     AZURE_COSMOSDB_CONVERSATIONS_CONTAINER: cosmosDbDatabaseContainerName
//     AZURE_COSMOSDB_DATABASE: cosmosDbDatabaseName
//     appInsightsConnectionString: aifoundry.outputs.applicationInsightsConnectionString
//     azureCosmosDbEnableFeedback: 'True'
//     hostingPlanName: 'asp-${solutionSuffix}'
//     websiteName: 'app-${solutionSuffix}'
//     aiSearchProjectConnectionName: aifoundry.outputs.aiSearchConnectionName
//     azureExistingAIProjectResourceId: azureExistingAIProjectResourceId
//     tags : tags
//   }
//   scope: resourceGroup(resourceGroup().name)
// }

// ========== Frontend server farm ========== //
var webServerFarmResourceName = 'asp-${solutionSuffix}'
module webServerFarm 'br/public:avm/res/web/serverfarm:0.5.0' = {
  name: take('avm.res.web.serverfarm.${webServerFarmResourceName}', 64)
  params: {
    name: webServerFarmResourceName
    tags: tags
    enableTelemetry: enableTelemetry
    location: solutionLocation
    reserved: true
    kind: 'linux'
    // WAF aligned configuration for Monitoring
    diagnosticSettings: enableMonitoring ? [{ workspaceResourceId: logAnalyticsWorkspaceResourceId }] : null
    // WAF aligned configuration for Scalability
    skuName: enableScalability || enableRedundancy ? 'P1v3' : 'B3'
    skuCapacity: enableScalability ? 3 : 1
    // WAF aligned configuration for Redundancy
    zoneRedundant: enableRedundancy ? true : false
  }
  scope: resourceGroup(resourceGroup().name)
  // dependsOn:[sqlDBModule]
}

@description('Contains WebApp URL')
output WEB_APP_URL string = appserviceModule.outputs.webAppUrl

// ========== Cosmos DB module ========== //
module cosmosDBModule 'deploy_cosmos_db.bicep' = {
  name: 'deploy_cosmos_db'
  params: {
    name: webSiteResourceName
    tags: tags
    location: solutionLocation
    kind: 'app,linux,container'
    serverFarmResourceId: webServerFarm.outputs.resourceId
    managedIdentities: { userAssignedResourceIds: [userAssignedIdentity!.outputs.resourceId] }
    siteConfig: {
      linuxFxVersion: 'DOCKER|${acrName}.azurecr.io/webapp:${imageTag}'
      minTlsVersion: '1.2'
    }
    configs: [
      {
        name: 'appsettings'
        properties: {
          SCM_DO_BUILD_DURING_DEPLOYMENT: 'true'
          DOCKER_REGISTRY_SERVER_URL: 'https://${acrName}.azurecr.io'
          // WEBSITES_PORT: '3000'
          // WEBSITES_CONTAINER_START_TIME_LIMIT: '1800' // 30 minutes, adjust as needed
          AUTH_ENABLED: 'false'
          AZURE_SEARCH_SERVICE: aiSearch.outputs.name
          AZURE_SEARCH_INDEX: 'pdf_index'
          AZURE_SEARCH_USE_SEMANTIC_SEARCH: 'False'
          AZURE_SEARCH_SEMANTIC_SEARCH_CONFIG: 'my-semantic-config'
          AZURE_SEARCH_INDEX_IS_PRECHUNKED: 'True'
          AZURE_SEARCH_TOP_K: '5'
          AZURE_SEARCH_ENABLE_IN_DOMAIN: 'True'
          AZURE_SEARCH_CONTENT_COLUMNS: 'content'
          AZURE_SEARCH_FILENAME_COLUMN: 'sourceurl'
          AZURE_SEARCH_TITLE_COLUMN: ''
          AZURE_SEARCH_URL_COLUMN: ''
          AZURE_SEARCH_QUERY_TYPE: 'simple'
          AZURE_SEARCH_VECTOR_COLUMNS: 'contentVector'
          AZURE_SEARCH_PERMITTED_GROUPS_COLUMN: ''
          AZURE_SEARCH_STRICTNESS: '3'
          AZURE_SEARCH_CONNECTION_NAME: aiSearchConnectionName
          AZURE_OPENAI_API_VERSION: azureOpenaiAPIVersion
          AZURE_OPENAI_MODEL: gptModelName
          AZURE_OPENAI_ENDPOINT: 'https://${aiFoundryAiServicesResourceName}.openai.azure.com/'
          AZURE_OPENAI_RESOURCE: aiFoundryAiServicesResourceName
          AZURE_OPENAI_PREVIEW_API_VERSION: azureOpenaiAPIVersion
          AZURE_OPENAI_GENERATE_SECTION_CONTENT_PROMPT: azureOpenAiGenerateSectionContentPrompt
          AZURE_OPENAI_TEMPLATE_SYSTEM_MESSAGE: azureOpenAiTemplateSystemMessage
          AZURE_OPENAI_TITLE_PROMPT: azureOpenAiTitlePrompt
          AZURE_OPENAI_SYSTEM_MESSAGE: azureOpenAISystemMessage
          AZURE_AI_AGENT_ENDPOINT: aiFoundryAiProjectEndpoint
          AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME: gptModelName
          AZURE_AI_AGENT_API_VERSION: azureAiAgentApiVersion
          SOLUTION_NAME: solutionName
          USE_CHAT_HISTORY_ENABLED: 'True'
          AZURE_COSMOSDB_ACCOUNT: cosmosDB.outputs.name
          AZURE_COSMOSDB_ACCOUNT_KEY: ''
          AZURE_COSMOSDB_CONVERSATIONS_CONTAINER: cosmosDBcollectionName
          AZURE_COSMOSDB_DATABASE: cosmosDBDatabaseName
          azureCosmosDbEnableFeedback: 'True'
          UWSGI_PROCESSES: '2'
          UWSGI_THREADS: '2'
          APP_ENV: 'Prod'
          AZURE_CLIENT_ID: userAssignedIdentity.outputs.clientId
        }
        // WAF aligned configuration for Monitoring
        applicationInsightResourceId: (enableMonitoring && !useExistingLogAnalytics) ? applicationInsights!.outputs.resourceId : null
      }
    ]
    diagnosticSettings: enableMonitoring ? [{ workspaceResourceId: logAnalyticsWorkspaceResourceId }] : null
    // WAF aligned configuration for Private Networking
    vnetRouteAllEnabled: enablePrivateNetworking ? true : false
    vnetImagePullEnabled: enablePrivateNetworking ? true : false
    virtualNetworkSubnetId: enablePrivateNetworking ? network!.outputs.subnetWebResourceId : null
    publicNetworkAccess: 'Enabled'
  }
}

// ========== App Service Logs Configuration ========== //
resource webSiteLogs 'Microsoft.Web/sites/config@2024-04-01' = if (enableMonitoring) {
  name: '${webSiteResourceName}/logs'
  properties: {
    applicationLogs: {
      fileSystem: {
        level: 'Verbose'  // Match the current configuration
      }
    }
    httpLogs: {
      fileSystem: {
        enabled: true
        retentionInDays: 3
        retentionInMb: 100
      }
    }
    detailedErrorMessages: {
      enabled: true
    }
    failedRequestsTracing: {
      enabled: true
    }
  }
  dependsOn: [webSite]
}

@description('Contains WebApp URL')
output webAppUrl string = 'https://${webSite.outputs.name}.azurewebsites.net'

@description('Contains Storage Account Name')
output STORAGE_ACCOUNT_NAME string = storageAccount.outputs.storageName

@description('Contains Storage Container Name')
output STORAGE_CONTAINER_NAME string = storageAccount.outputs.storageContainer

@description('Contains KeyVault Name')
output KEY_VAULT_NAME string = kvault.outputs.keyvaultName

@description('Contains CosmosDB Account Name')
output COSMOSDB_ACCOUNT_NAME string = cosmosDBModule.outputs.cosmosAccountName

@description('Contains Resource Group Name')
output RESOURCE_GROUP_NAME string = resourceGroup().name

@description('Contains AI Foundry Name')
output AI_FOUNDRY_NAME string = aifoundry.outputs.aiFoundryName

@description('Contains AI Foundry RG Name')
output AI_FOUNDRY_RG_NAME string = aifoundry.outputs.aiFoundryRgName

@description('Contains AI Foundry Resource ID')
output AI_FOUNDRY_RESOURCE_ID string = aifoundry.outputs.aiFoundryId

@description('Contains AI Search Service Name')
output AI_SEARCH_SERVICE_NAME string = aifoundry.outputs.aiSearchService

@description('Contains Azure Search Connection Name')
output AZURE_SEARCH_CONNECTION_NAME string = aifoundry.outputs.aiSearchConnectionName

@description('Contains OpenAI Title Prompt')
output AZURE_OPENAI_TITLE_PROMPT string = appserviceModule.outputs.azureOpenAiTitlePrompt

@description('Contains OpenAI Generate Section Content Prompt')
output AZURE_OPENAI_GENERATE_SECTION_CONTENT_PROMPT string = appserviceModule.outputs.azureOpenAiGenerateSectionContentPrompt

@description('Contains OpenAI Template System Message')
output AZURE_OPENAI_TEMPLATE_SYSTEM_MESSAGE string = appserviceModule.outputs.azureOpenAiTemplateSystemMessage

@description('Contains OpenAI System Message')
output AZURE_OPENAI_SYSTEM_MESSAGE string = appserviceModule.outputs.azureOpenAISystemMessage

@description('Contains OpenAI Model')
output AZURE_OPENAI_MODEL string = appserviceModule.outputs.azureOpenAIModel

@description('Contains OpenAI Resource')
output AZURE_OPENAI_RESOURCE string = appserviceModule.outputs.azureOpenAIResource

@description('Contains Azure Search Service')
output AZURE_SEARCH_SERVICE string = appserviceModule.outputs.aiSearchService

@description('Contains Azure Search Index')
output AZURE_SEARCH_INDEX string = appserviceModule.outputs.AzureSearchIndex

@description('Contains CosmosDB Account')
output AZURE_COSMOSDB_ACCOUNT string = cosmosDBModule.outputs.cosmosAccountName

@description('Contains CosmosDB Database')
output AZURE_COSMOSDB_DATABASE string = cosmosDBModule.outputs.cosmosDatabaseName

@description('Contains CosmosDB Conversations Container')
output AZURE_COSMOSDB_CONVERSATIONS_CONTAINER string = cosmosDBModule.outputs.cosmosContainerName

@description('Contains CosmosDB Enabled Feedback')
output AZURE_COSMOSDB_ENABLE_FEEDBACK string = appserviceModule.outputs.azureCosmosDbEnableFeedback

@description('Contains Search Query Type')
output AZURE_SEARCH_QUERY_TYPE string = appserviceModule.outputs.AzureSearchQueryType

@description('Contains Search Vector Columns')
output AZURE_SEARCH_VECTOR_COLUMNS string = appserviceModule.outputs.AzureSearchVectorFields

@description('Contains AI Agent Endpoint')
output AZURE_AI_AGENT_ENDPOINT string = aifoundry.outputs.aiFoundryProjectEndpoint

@description('Contains AI Agent API Version')
output AZURE_AI_AGENT_API_VERSION string = azureAiAgentApiVersion

@description('Contains AI Agent Model Deployment Name')
output AZURE_AI_AGENT_MODEL_DEPLOYMENT_NAME string = appserviceModule.outputs.azureOpenAIModel

@description('Contains Application Insights Connection String')
output AZURE_APPLICATION_INSIGHTS_CONNECTION_STRING string = aifoundry.outputs.applicationInsightsConnectionString

@description('Contains Application Environment.')
output APP_ENV string  = appserviceModule.outputs.appEnv
