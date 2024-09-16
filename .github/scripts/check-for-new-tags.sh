#!/bin/bash

set -e

new_tags=()

# Define temporary files
rancher_tags_file=$(mktemp -p /tmp)
upstream_tags_file=$(mktemp -p /tmp)

# Fetch tags from the rancher/kubernetes repository and save to a temp file
git ls-remote --tags --refs --sort='-v:refname' https://github.com/rancher/kubernetes.git > "$rancher_tags_file"

# Fetch tags from the upstream kubernetes repository and save to a temp file
git ls-remote --tags --refs --sort='-v:refname' https://github.com/kubernetes/kubernetes.git | head -n 100 | awk '{print $2}' | sed 's|refs/tags/||' > "$upstream_tags_file"

# Check if upstream_tags_file is empty
if [ ! -s "$upstream_tags_file" ]; then
    echo "No tags found in upstream kubernetes."
    rm -f "$rancher_tags_file" "$upstream_tags_file"
    exit 1
fi

# Process each tag
while read -r tag; do
    # Skip tags with "rc", "alpha", or "beta"
    if [[ "$tag" == *"rc"* || "$tag" == *"alpha"* || "$tag" == *"beta"* ]]; then
        continue
    fi

    # Check if the tag already exists in the rancher repository
    if grep -q "refs/tags/${tag}" "$rancher_tags_file"; then
        continue
    else
        # Check if the tag has a newer patch release already available
        latest_patch_in_rancher=$(grep "$(echo "${tag}" | cut -d '.' -f 1,2)" "$rancher_tags_file" | awk '{print $2}' | sed 's|refs/tags/||' | head -n 1)
        if [ "$(printf '%s\n' "${tag}" "${latest_patch_in_rancher}" | sort -V | tail -n 1)" = "${tag}" ]; then
            new_tags+=( "${tag}" )
        fi
    fi
done < "$upstream_tags_file"

# In-place reverse
for (( i=0, j=${#new_tags[@]}-1; i<j; i++, j-- )); do
    temp="${new_tags[i]}"
    new_tags[i]="${new_tags[j]}"
    new_tags[j]="$temp"
done

# Print the new tags
if [ ${#new_tags[@]} -eq 0 ]; then
    echo "No new tags to create branches for."
else
    echo "New tags to create branches for:"
    for tag in "${new_tags[@]}"; do
        echo "$tag"
    done
fi

echo "NEW_TAGS=${new_tags[@]}" >> $GITHUB_ENV

# Clean up temporary files
rm -f "$rancher_tags_file" "$upstream_tags_file"
