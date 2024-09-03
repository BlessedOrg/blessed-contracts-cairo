#!/bin/bash

# Assuming your folder structure is:
#         $your_parent_folder
#            /        \
#    $we_are_here  blessed-dashboard

# Base directories
app_artifacts_dir="../blessed-dashboard/src/contracts/artifacts"

# Loop through each folder in the blessed-cairo-contracts directory
for dir in */; do
    # Get the folder name
    contract_name=$(basename "$dir")
    if [ "$contract_name" = "node_modules" ]; then
        continue
    fi
    echo "🔁🔁🔁"
    echo "📜 Contract Name: $contract_name"

    # Navigate to the target/dev directory
    target_dir="${dir}target/dev"
    echo "🎯 Navigating to: $target_dir"

    # Find the JSON file containing 'contract_class' in its name
    json_file=$(find "$target_dir" -type f -name '*contract_class*.json')
    echo "💽 Found JSON file: $json_file"

    # Copy the found JSON file to the artifacts directory with the new name
    new_file_path="$app_artifacts_dir/${contract_name}.json"
    cp "$json_file" "$new_file_path"
    echo "📝 Copied to: $new_file_path"
done

echo "________________________"
echo "Copied successfully! 🤘"
