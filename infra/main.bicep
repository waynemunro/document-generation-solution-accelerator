// ========== main.bicep ========== //
targetScope = 'resourceGroup'

@minLength(3)
@maxLength(15)
@description('Optional. A unique prefix for all resources in this deployment. This should be 3-15 characters long:')
param solutionName string = 'docgen'

@minLength(1)
@description('Optional. Secondary location for databases creation(example:eastus2):')
param secondaryLocation string = 'eastus2'

@description('Optional. Azure location for the solution. If not provided, it defaults to the resource group location.')
param AZURE_LOCATION string = ''

// ========== AI Deployments Location ========== //
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
      'OpenAI.GlobalStandard.gpt4.1,150'
      'OpenAI.GlobalStandard.text-embedding-ada-002,80'
    ]
  }
})
param aiDeploymentsLocation string

@minLength(1)
@description('Optional. GPT model deployment type:')
@allowed([
  'Standard'
  'GlobalStandard'
])
param deploymentType string = 'GlobalStandard'

@description('Optional. Name of the GPT model to deploy:')
param gptModelName string = 'gpt-4.1'

@description('Optional. Version of the GPT model to deploy:')
param gptModelVersion string = '2025-04-14'

@description('Optional. API version for Azure OpenAI service. This should be a valid API version supported by the service.')
param azureOpenaiAPIVersion string = '2025-01-01-preview'

@description('Optional. API version for Azure AI Agent service. This should be a valid API version supported by the service.')
param azureAiAgentApiVersion string = '2025-05-01'

@minValue(10)
@description('Optional. Capacity of the GPT deployment:')
// You can increase this, but capacity is limited per model/region, so you will get errors if you go over
// https://learn.microsoft.com/en-us/azure/ai-services/openai/quotas-limits
param gptDeploymentCapacity int = 150

@minLength(1)
@description('Optional. Name of the Text Embedding model to deploy:')
param embeddingModel string = 'text-embedding-ada-002'

//var abbrs = loadJsonContent('./abbreviations.json')
@minValue(10)
@description('Optional. Capacity of the Embedding Model deployment')
param embeddingDeploymentCapacity int = 80

@description('Optional. Image tag for the App Service container. Default is "latest".')
param imageTag string = 'latest'

@description('Optional. Existing Log Analytics Workspace Resource ID')
param existingLogAnalyticsWorkspaceId string = ''

@description('Optional. Use this parameter to use an existing AI project resource ID')
param azureExistingAIProjectResourceId string = ''

var solutionLocation = empty(AZURE_LOCATION) ? resourceGroup().location : AZURE_LOCATION

//var solutionPrefix = 'dg${padLeft(take(toLower(uniqueString(subscription().id, solutionName, resourceGroup().location,resourceGroup().name)), 12), 12, '0')}'

@maxLength(5)
@description('Optional. A unique text value for the solution. This is used to ensure resource names are unique for global resources. Defaults to a 5-character substring of the unique string generated from the subscription ID, resource group name, and solution name.')
param solutionUniqueText string = substring(uniqueString(subscription().id, resourceGroup().name, solutionName), 0, 5)

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

// ========== Managed Identity ========== //
module managedIdentityModule 'deploy_managed_identity.bicep' = {
  name: 'deploy_managed_identity'
  params: {
    solutionName: solutionSuffix
    solutionLocation: solutionLocation
    miName: 'id-${solutionSuffix}'
    tags : tags
  }
  scope: resourceGroup(resourceGroup().name)
}

// ==========Key Vault Module ========== //
module kvault 'deploy_keyvault.bicep' = {
  name: 'deploy_keyvault'
  params: {
    solutionName: solutionSuffix
    solutionLocation: solutionLocation
    managedIdentityObjectId: managedIdentityModule.outputs.managedIdentityOutput.objectId
    keyvaultName: 'kv-${solutionSuffix}'
    tags : tags
  }
  scope: resourceGroup(resourceGroup().name)
}

// ==========AI Foundry and related resources ========== //
module aifoundry 'deploy_ai_foundry.bicep' = {
  name: 'deploy_ai_foundry'
  params: {
    solutionName: solutionSuffix
    solutionLocation: aiDeploymentsLocation
    keyVaultName: kvault.outputs.keyvaultName
    deploymentType: deploymentType
    gptModelName: gptModelName
    gptModelVersion: gptModelVersion
    azureOpenaiAPIVersion: azureOpenaiAPIVersion
    gptDeploymentCapacity: gptDeploymentCapacity
    embeddingModel: embeddingModel
    embeddingDeploymentCapacity: embeddingDeploymentCapacity
    managedIdentityObjectId: managedIdentityModule.outputs.managedIdentityOutput.objectId
    existingLogAnalyticsWorkspaceId: existingLogAnalyticsWorkspaceId
    azureExistingAIProjectResourceId: azureExistingAIProjectResourceId
    tags : tags
  }
  scope: resourceGroup(resourceGroup().name)
}

// ========== Storage account module ========== //
module storageAccount 'deploy_storage_account.bicep' = {
  name: 'deploy_storage_account'
  params: {
    solutionName: solutionSuffix
    solutionLocation: solutionLocation
    keyVaultName: kvault.outputs.keyvaultName
    managedIdentityObjectId: managedIdentityModule.outputs.managedIdentityOutput.objectId
    saName: 'st${solutionSuffix}'
    tags : tags
  }
  scope: resourceGroup(resourceGroup().name)
}

//========== Updates to Key Vault ========== //
resource keyVault 'Microsoft.KeyVault/vaults@2022-07-01' existing = {
  name: aifoundry.outputs.keyvaultName
  scope: resourceGroup(resourceGroup().name)
}

//========== App service module ========== //
module appserviceModule 'deploy_app_service.bicep' = {
  name: 'deploy_app_service'
  params: {
    imageTag: imageTag
    applicationInsightsId: aifoundry.outputs.applicationInsightsId
    // identity:managedIdentityModule.outputs.managedIdentityOutput.id
    solutionName: solutionSuffix
    solutionLocation: solutionLocation
    aiSearchService: aifoundry.outputs.aiSearchService
    aiSearchName: aifoundry.outputs.aiSearchName
    azureAiAgentApiVersion: azureAiAgentApiVersion
    azureOpenAIEndpoint: aifoundry.outputs.aoaiEndpoint
    azureOpenAIModel: gptModelName
    azureOpenAIApiVersion: azureOpenaiAPIVersion //'2024-02-15-preview'
    azureOpenaiResource: aifoundry.outputs.aiFoundryName
    aiFoundryProjectName: aifoundry.outputs.aiFoundryProjectName
    aiFoundryName: aifoundry.outputs.aiFoundryName
    aiFoundryProjectEndpoint: aifoundry.outputs.aiFoundryProjectEndpoint
    USE_CHAT_HISTORY_ENABLED: 'True'
    AZURE_COSMOSDB_ACCOUNT: cosmosDBModule.outputs.cosmosAccountName
    // AZURE_COSMOSDB_ACCOUNT_KEY: keyVault.getSecret('AZURE-COSMOSDB-ACCOUNT-KEY')
    AZURE_COSMOSDB_CONVERSATIONS_CONTAINER: cosmosDBModule.outputs.cosmosContainerName
    AZURE_COSMOSDB_DATABASE: cosmosDBModule.outputs.cosmosDatabaseName
    appInsightsConnectionString: aifoundry.outputs.applicationInsightsConnectionString
    azureCosmosDbEnableFeedback: 'True'
    hostingPlanName: 'asp-${solutionSuffix}'
    websiteName: 'app-${solutionSuffix}'
    aiSearchProjectConnectionName: aifoundry.outputs.aiSearchConnectionName
    azureExistingAIProjectResourceId: azureExistingAIProjectResourceId
    tags : tags
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
    solutionName: solutionSuffix
    solutionLocation: secondaryLocation
    keyVaultName: kvault.outputs.keyvaultName
    accountName: 'cosmos-${solutionSuffix}'
    tags : tags
  }
  scope: resourceGroup(resourceGroup().name)
}

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
