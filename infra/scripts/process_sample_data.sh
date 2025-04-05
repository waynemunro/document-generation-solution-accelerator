#!/bin/bash

# Variables
storageAccount="$1"
fileSystem="$2"
keyvaultName="$3"
managedIdentityClientId="$4"

# Check if all required arguments are provided
if [ -z "$storageAccount" ] || [ -z "$fileSystem" ] || [ -z "$keyvaultName" ]; then
    echo "Usage: $0 <storageAccount> <fileSystem> <keyvaultName> [managedIdentityClientId]"
    exit 1
fi

# Call copy_kb_files.sh
echo "Running copy_kb_files.sh"
bash infra/scripts/copy_kb_files.sh "$storageAccount" "$fileSystem" "$managedIdentityClientId"
if [ $? -ne 0 ]; then
    echo "Error: copy_kb_files.sh failed."
    exit 1
fi
echo "copy_kb_files.sh completed successfully."

# Call run_create_index_scripts.sh
echo "Running run_create_index_scripts.sh"
bash infra/scripts/run_create_index_scripts.sh "$keyvaultName" "$managedIdentityClientId"
if [ $? -ne 0 ]; then
    echo "Error: run_create_index_scripts.sh failed."
    exit 1
fi
echo "run_create_index_scripts.sh completed successfully."

echo "All scripts executed successfully."