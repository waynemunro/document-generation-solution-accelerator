#!/bin/bash

# Default Models and Capacities (Comma-separated in "model:capacity" format)
DEFAULT_MODEL_CAPACITY="gpt-4o:30,text-embedding-ada-002:80,gpt-4:30"

# Convert the comma-separated string into an array
IFS=',' read -r -a MODEL_CAPACITY_PAIRS <<< "$DEFAULT_MODEL_CAPACITY"

# Default Regions to check (Comma-separated, now configurable)
DEFAULT_REGIONS="eastus,uksouth,eastus2,northcentralus,swedencentral,westus,westus2,southcentralus,canadacentral"
IFS=',' read -r -a DEFAULT_REGION_ARRAY <<< "$DEFAULT_REGIONS"

# Read parameters (if any)
IFS=',' read -r -a USER_PROVIDED_PAIRS <<< "$1"
USER_REGION="$2"

IS_USER_PROVIDED_PAIRS=false

if [ ${#USER_PROVIDED_PAIRS[@]} -lt 1 ]; then
    echo "No parameters provided, using default model-capacity pairs: ${MODEL_CAPACITY_PAIRS[*]}"
else
    echo "Using provided model and capacity pairs: ${USER_PROVIDED_PAIRS[*]}"
    IS_USER_PROVIDED_PAIRS=true
    MODEL_CAPACITY_PAIRS=("${USER_PROVIDED_PAIRS[@]}")
fi

declare -a FINAL_MODEL_NAMES
declare -a FINAL_CAPACITIES
declare -a TABLE_ROWS

for PAIR in "${MODEL_CAPACITY_PAIRS[@]}"; do
    MODEL_NAME=$(echo "$PAIR" | cut -d':' -f1 | tr '[:upper:]' '[:lower:]')
    CAPACITY=$(echo "$PAIR" | cut -d':' -f2)

    if [ -z "$MODEL_NAME" ] || [ -z "$CAPACITY" ]; then
        echo "❌ ERROR: Invalid model and capacity pair '$PAIR'. Both model and capacity must be specified."
        exit 1
    fi

    FINAL_MODEL_NAMES+=("$MODEL_NAME")
    FINAL_CAPACITIES+=("$CAPACITY")

done

echo "🔄 Using Models: ${FINAL_MODEL_NAMES[*]} with respective Capacities: ${FINAL_CAPACITIES[*]}"
echo "----------------------------------------"

# Check if the user provided a region, if not, use the default regions
if [ -n "$USER_REGION" ]; then
    echo "🔍 User provided region: $USER_REGION"
    IFS=',' read -r -a REGIONS <<< "$USER_REGION"
else
    echo "No region specified, using default regions: ${DEFAULT_REGION_ARRAY[*]}"
    REGIONS=("${DEFAULT_REGION_ARRAY[@]}")
    APPLY_OR_CONDITION=true
fi

echo "✅ Retrieved Azure regions. Checking availability..."
INDEX=1

VALID_REGIONS=()
for REGION in "${REGIONS[@]}"; do
    echo "----------------------------------------"
    echo "🔍 Checking region: $REGION"

    QUOTA_INFO=$(az cognitiveservices usage list --location "$REGION" --output json | tr '[:upper:]' '[:lower:]')
    if [ -z "$QUOTA_INFO" ]; then
        echo "⚠️ WARNING: Failed to retrieve quota for region $REGION. Skipping."
        continue
    fi

    TEXT_EMBEDDING_AVAILABLE=false
    AT_LEAST_ONE_MODEL_AVAILABLE=false
    TEMP_TABLE_ROWS=()

    for index in "${!FINAL_MODEL_NAMES[@]}"; do
        MODEL_NAME="${FINAL_MODEL_NAMES[$index]}"
        REQUIRED_CAPACITY="${FINAL_CAPACITIES[$index]}"
        FOUND=false
        INSUFFICIENT_QUOTA=false

        if [ "$MODEL_NAME" = "text-embedding-ada-002" ]; then
            MODEL_TYPES=("openai.standard.$MODEL_NAME")
        else
            MODEL_TYPES=("openai.standard.$MODEL_NAME" "openai.globalstandard.$MODEL_NAME")
        fi

        for MODEL_TYPE in "${MODEL_TYPES[@]}"; do
            FOUND=false
            INSUFFICIENT_QUOTA=false
            echo "🔍 Checking model: $MODEL_NAME with required capacity: $REQUIRED_CAPACITY ($MODEL_TYPE)"

            MODEL_INFO=$(echo "$QUOTA_INFO" | awk -v model="\"value\": \"$MODEL_TYPE\"" '
                BEGIN { RS="},"; FS="," }
                $0 ~ model { print $0 }
            ')

            if [ -z "$MODEL_INFO" ]; then
                FOUND=false
                echo "⚠️ WARNING: No quota information found for model: $MODEL_NAME in region: $REGION for model type: $MODEL_TYPE."
                continue
            fi

            if [ -n "$MODEL_INFO" ]; then
                FOUND=true
                CURRENT_VALUE=$(echo "$MODEL_INFO" | awk -F': ' '/"currentvalue"/ {print $2}' | tr -d ',' | tr -d ' ')
                LIMIT=$(echo "$MODEL_INFO" | awk -F': ' '/"limit"/ {print $2}' | tr -d ',' | tr -d ' ')

                CURRENT_VALUE=${CURRENT_VALUE:-0}
                LIMIT=${LIMIT:-0}

                CURRENT_VALUE=$(echo "$CURRENT_VALUE" | cut -d'.' -f1)
                LIMIT=$(echo "$LIMIT" | cut -d'.' -f1)

                AVAILABLE=$((LIMIT - CURRENT_VALUE))
                echo "✅ Model: $MODEL_TYPE | Used: $CURRENT_VALUE | Limit: $LIMIT | Available: $AVAILABLE"

                if [ "$AVAILABLE" -ge "$REQUIRED_CAPACITY" ]; then
                    FOUND=true
                    if [ "$MODEL_NAME" = "text-embedding-ada-002" ]; then
                        TEXT_EMBEDDING_AVAILABLE=true
                    fi
                    AT_LEAST_ONE_MODEL_AVAILABLE=true
                    TEMP_TABLE_ROWS+=("$(printf "| %-4s | %-20s | %-60s | %-10s | %-10s | %-10s |" "$INDEX" "$REGION" "$MODEL_TYPE" "$LIMIT" "$CURRENT_VALUE" "$AVAILABLE")")
                else
                    INSUFFICIENT_QUOTA=true
                fi
            fi
            
            if [ "$FOUND" = false ]; then
                echo "❌ No models found for model: $MODEL_NAME in region: $REGION (${MODEL_TYPES[*]})"
            elif [ "$INSUFFICIENT_QUOTA" = true ]; then
                echo "⚠️ Model $MODEL_NAME in region: $REGION has insufficient quota (${MODEL_TYPES[*]})."
            fi
        done
    done

if { [ "$IS_USER_PROVIDED_PAIRS" = true ] && [ "$INSUFFICIENT_QUOTA" = false ] && [ "$FOUND" = true ]; } || { [ "$TEXT_EMBEDDING_AVAILABLE" = true ] && { [ "$APPLY_OR_CONDITION" != true ] || [ "$AT_LEAST_ONE_MODEL_AVAILABLE" = true ]; }; }; then
        VALID_REGIONS+=("$REGION")
        TABLE_ROWS+=("${TEMP_TABLE_ROWS[@]}")
        INDEX=$((INDEX + 1))
    elif [ ${#USER_PROVIDED_PAIRS[@]} -eq 0 ]; then
        echo "🚫 Skipping $REGION as it does not meet quota requirements."
    fi

done

if [ ${#TABLE_ROWS[@]} -eq 0 ]; then
    echo "----------------------------------------------------------------------------------------------------------"

    echo "❌ No regions have sufficient quota for all required models. Please request a quota increase: https://aka.ms/oai/stuquotarequest"
else
    echo "----------------------------------------------------------------------------------------------------------"
    printf "| %-4s | %-20s | %-60s | %-10s | %-10s | %-10s |\n" "No." "Region" "Model Name" "Limit" "Used" "Available"
    echo "----------------------------------------------------------------------------------------------------------"
    for ROW in "${TABLE_ROWS[@]}"; do
        echo "$ROW"
    done
    echo "----------------------------------------------------------------------------------------------------------"
    echo "➡️  To request a quota increase, visit: https://aka.ms/oai/stuquotarequest"
fi

echo "✅ Script completed."
