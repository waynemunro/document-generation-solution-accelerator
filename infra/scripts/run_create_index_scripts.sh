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
az role assignment create --assignee $signed_user_id --role "Key Vault Administrator" --scope /$key_vault_resource_id

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
sed -i "s/kv_to-be-replaced/${keyvaultName}/g" "infra/scripts/index_scripts/02_process_data.py"
if [ -n "$managedIdentityClientId" ]; then
    sed -i "s/mici_to-be-replaced/${managedIdentityClientId}/g" "infra/scripts/index_scripts/01_create_search_index.py"
    sed -i "s/mici_to-be-replaced/${managedIdentityClientId}/g" "infra/scripts/index_scripts/02_process_data.py"
fi


# create virtual environment
echo "Creating virtual environment"
# Check if the virtual environment already exists
if [ -d "infra/scripts/scriptenv" ]; then
    echo "Virtual environment already exists. Skipping creation."
else
    echo "Creating virtual environment"
    python3 -m venv infra/scripts/scriptenv
fi
source infra/scripts/scriptenv/Scripts/activate

# Install the requirements
echo "Installing requirements"
pip install -r infra/scripts/index_scripts/requirements.txt
echo "Requirements installed"

# Run the scripts
echo "Running the scripts"
echo "Creating the search index"
python infra/scripts/index_scripts/01_create_search_index.py
echo "Processing the data"
python infra/scripts/index_scripts/02_process_data.py
echo "Scripts completed"
