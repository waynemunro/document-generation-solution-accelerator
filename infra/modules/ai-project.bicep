@description('Required. Name of the AI Services project.')
param name string

@description('Required. The location of the Project resource.')
param location string = resourceGroup().location

@description('Optional. The description of the AI Foundry project to create. Defaults to the project name.')
param desc string = name

@description('Required. Name of the existing Cognitive Services resource to create the AI Foundry project in.')
param aiServicesName string

@description('Required. Azure Existing AI Project ResourceID.')
param azureExistingAIProjectResourceId string = ''

@description('Required. Contains Solution Name')
param solutionName string

@description('Optional. Tags to be applied to the resources.')
param tags object = {}

var aiSearchName = 'srch-${solutionName}'
var aiSearchConnectionName = 'foundry-search-connection-${solutionName}'
var useExistingAiFoundryAiProject = !empty(azureExistingAIProjectResourceId)
var aiFoundryAiServicesResourceGroupName = useExistingAiFoundryAiProject
  ? split(azureExistingAIProjectResourceId, '/')[4]
  : ''
var aiFoundryAiServicesResourceName = useExistingAiFoundryAiProject
  ? split(azureExistingAIProjectResourceId, '/')[8]
  : ''
var aiFoundryAiServicesSubscriptionId = useExistingAiFoundryAiProject
  ? split(azureExistingAIProjectResourceId, '/')[2]
  : subscription().id
var aiFoundryAiProjectResourceName = useExistingAiFoundryAiProject
  ? split(azureExistingAIProjectResourceId, '/')[10]
  : ''
var existingOpenAIEndpoint = useExistingAiFoundryAiProject
  ? format('https://{0}.openai.azure.com/', split(azureExistingAIProjectResourceId, '/')[8])
  : ''
// Reference to cognitive service in current resource group for new projects
resource cogServiceReference 'Microsoft.CognitiveServices/accounts@2025-06-01' existing = {
  name: aiServicesName
}

resource aiProject 'Microsoft.CognitiveServices/accounts/projects@2025-06-01' = {
  parent: cogServiceReference
  name: name
  tags: tags
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: desc
    displayName: name
  }
}

resource aiSearch 'Microsoft.Search/searchServices@2024-06-01-preview' = {
  name: aiSearchName
  location: location
  sku: {
    name: 'basic'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    replicaCount: 1
    partitionCount: 1
    hostingMode: 'default'
    publicNetworkAccess: 'enabled'
    networkRuleSet: {
      ipRules: []
    }
    encryptionWithCmk: {
      enforcement: 'Unspecified'
    }
    disableLocalAuth: true
    semanticSearch: 'free'
  }
  tags : tags
}

resource aiSearchFoundryConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = if (!useExistingAiFoundryAiProject) {
  name: aiSearchConnectionName
  parent: aiProject
  properties: {
    category: 'CognitiveSearch'
    target: 'https://${aiSearchName}.search.windows.net'
    authType: 'AAD'
    isSharedToAll: true
    metadata: {
      ApiType: 'Azure'
      ResourceId: aiSearch.id
      location: aiSearch.location
    }
  }
}

module existing_AIProject_SearchConnectionModule 'deploy_aifp_aisearch_connection.bicep' = if (useExistingAiFoundryAiProject) {
  name: 'aiProjectSearchConnectionDeployment'
  scope: resourceGroup(aiFoundryAiServicesSubscriptionId, aiFoundryAiServicesResourceGroupName)
  params: {
    existingAIProjectName: aiFoundryAiProjectResourceName
    existingAIFoundryName: aiFoundryAiServicesResourceName
    aiSearchName: aiSearchName
    aiSearchResourceId: aiSearch.id
    aiSearchLocation: aiSearch.location
    aiSearchConnectionName: aiSearchConnectionName
  }
}

@description('Required. Name of the AI project.')
output name string = aiProject.name

@description('Required. Resource ID of the AI project.')
output resourceId string = aiProject.id

@description('Required. API endpoint for the AI project.')
output apiEndpoint string = aiProject!.properties.endpoints['AI Foundry API']

@description('Contains AI Endpoint.')
output aoaiEndpoint string = !empty(existingOpenAIEndpoint)
  ? existingOpenAIEndpoint
  : cogServiceReference.properties.endpoints['OpenAI Language Model Instance API']

@description('Contains AI Search Service.')
output aiSearchServiceName string = aiSearch.name

@description('Contains Name of AI Search Connection.')
output aiSearchConnectionName string = aiSearchConnectionName
