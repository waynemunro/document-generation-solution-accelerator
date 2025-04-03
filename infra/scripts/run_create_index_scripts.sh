#!/bin/bash
echo "started the script"

# Variables
# baseUrl="$1"
keyvaultName="$1"
managedIdentityClientId="$2"
# requirementFile="infra/scripts/index_scripts/requirements.txt"
# requirementFileUrl=${baseUrl}"infra/scripts/index_scripts/requirements.txt"

echo "Script Started"

echo "Getting signed in user id"
signed_user_id=$(az ad signed-in-user show --query id -o tsv)

# # Download the create_index and create table python files
# curl --output "01_create_search_index.py" ${baseUrl}"infra/scripts/index_scripts/01_create_search_index.py"
# curl --output "02_process_data.py" ${baseUrl}"infra/scripts/index_scripts/02_process_data.py"

# Define the scope for the Key Vault (replace with your Key Vault resource ID)
echo "Getting key vault resource id"
key_vault_resource_id=$(az keyvault show --name $keyvaultName --query id --output tsv)

# Assign the Key Vault Administrator role to the user
echo "Assigning the Key Vault Administrator role to the user."
az role assignment create --assignee $signed_user_id --role "Key Vault Administrator" --scope $key_vault_resource_id

# RUN apt-get update
# RUN apt-get install python3 python3-dev g++ unixodbc-dev unixodbc libpq-dev
# apk add python3 python3-dev g++ unixodbc-dev unixodbc libpq-dev
 
# # RUN apt-get install python3 python3-dev g++ unixodbc-dev unixodbc libpq-dev
# pip install pyodbc

# Download the requirement file
# curl --output "$requirementFile" "$requirementFileUrl"

# echo "Download completed"

#Replace key vault name 
sed -i "s/kv_to-be-replaced/${keyvaultName}/g" "infra/scripts/index_scripts/01_create_search_index.py"
sed -i "s/mici_to-be-replaced/${managedIdentityClientId}/g" "infra/scripts/index_scripts/01_create_search_index.py"
sed -i "s/kv_to-be-replaced/${keyvaultName}/g" "infra/scripts/index_scripts/02_process_data.py"
sed -i "s/mici_to-be-replaced/${managedIdentityClientId}/g" "infra/scripts/index_scripts/02_process_data.py"

pip install -r infra/scripts/index_scripts/requirements.txt

python infra/scripts/index_scripts/01_create_search_index.py
python infra/scripts/index_scripts/02_process_data.py
