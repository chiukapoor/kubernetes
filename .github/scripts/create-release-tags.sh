#!/bin/bash

set -e

NEW_RELEASE_BRANCHES=()

echo "Setting up git user and upstream in git repository."

# Configure Git user
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config --global user.name "github-actions[bot]"

# Define temporary files
rancher_tags_file=$(mktemp -p /tmp)


# Extract the latest tag from rancher/kubernetes
git for-each-ref --sort='-creatordate' --format '%(refname:short)' refs/tags > "$rancher_tags_file"

# Check if upstream_tags_file is empty
if [ ! -s "$rancher_tags_file" ]; then
    echo "No tags found in rancher/kubernetes."
    rm -f "$rancher_tags_file"
    exit 1
fi

# Add upstream remote if not already added
if ! git remote get-url upstream &>/dev/null; then
    git remote add "upstream" https://github.com/kubernetes/kubernetes.git
fi

# Fetch upstream tags
git fetch --tags --quiet upstream || true

# Process each tag
for tag in $NEW_TAGS; do
    echo "Processing tag: ${tag}"
    
    # Extract major and minor version from the tag
    major_minor=$(echo "${tag}" | cut -d '.' -f 1,2)

    # Try to find the latest tag with the same major and minor version
    last_latest_tag=$(grep "${major_minor}" "$rancher_tags_file" | head -1)

    # If not found, look for the previous minor version
    if [ -z "$last_latest_tag" ]; then
        major_minor=$(echo "${major_minor}" | awk -F. '{print $1 "." $2-1}')
        last_latest_tag=$(grep "${major_minor}" "$rancher_tags_file" | head -1)
    fi
    echo "Rancher latest tag: ${last_latest_tag}"

    # Find commits hash of latest commit from a specific user
    latest_commit_of_user=$(git log --format='%H' --author="k8s-release-robot@users.noreply.github.com" "${last_latest_tag}" | head -1)
    if [ -z "$latest_commit_of_user" ]; then
        echo "No commit from the specific user found."
        exit 1
    fi
    echo "Latest commit hash of k8s user: ${latest_commit_of_user}"

    head_of_last_latest_tag=$(git rev-list "${last_latest_tag}" | head -1)
    echo "Head commit hash of tag ${last_latest_tag}: ${head_of_last_latest_tag}"

    # List of commits to cherry pick
    cherry_pick_commits=$(git rev-list --no-merges --reverse --ancestry-path "${last_latest_tag}" "$latest_commit_of_user".."$head_of_last_latest_tag")

    git checkout -b "release-${tag}" $tag
    FAIL=0
    # Cherry-pick all commits before the user's commit
    for commit in $cherry_pick_commits; do
        if [[ $(git log --format=%B -n 1 $commit) == *"vendor update"* ]]; then
            echo "This is a vendor commit, not cherry picking."
            echo "Performing './hack/update-vendor.sh'"
            if ! ./hack/update-vendor.sh > /dev/null; then
                echo "Warning: Error during vendor update for tag $tag. Skipping the tag."
                FAIL=1
                continue
            fi
            echo "Commit vendor update changes"
            git add .
            if ! git commit -m "vendor update" > /dev/null; then
                echo "Warning: Error commiting changes for tag $tag. Skipping the tag."
                FAIL=1
                continue
            fi
        else
            echo "Cherry pick commit: $commit to branch: release-${tag}"
            if ! git cherry-pick "$commit"  > /dev/null; then
                echo "Warning: Error during cherry-pick for tag $tag. Skipping the tag."
                git cherry-pick --abort
                FAIL=1
                continue
            fi
        fi
        if [[ $FAIL == 1 ]]; then
            break
        fi
    done

    if [[ $FAIL == 0 ]]; then
        echo "Cherry pick completed successfully. Pushing branch release-${tag} to rancher repository."
        if ! $(git push -u https://github.com/chiukapoor/kubernetes.git release-${tag} > /dev/null); then
            echo "Warning: Error while pushing the branch release-${tag} to rancher repository."
            exit 1
        else
            NEW_RELEASE_BRANCHES+=( "release-${tag}" )
            echo "Successfully pushed branch release-${tag}: https://github.com/chiukapoor/kubernetes/tree/release-${tag}"
        fi
    fi

    echo "========================================================================================"
done

# Print the new branches
if [ ${#NEW_RELEASE_BRANCHES[@]} -eq 0 ]; then
    echo "No new release branches."
else
    echo "New release branches:"
    for branch in "${NEW_RELEASE_BRANCHES[@]}"; do
        echo "$branch"
    done
fi

# Convert NEW_RELEASE_BRANCHES array to JSON string
echo "NEW_RELEASE_BRANCHES=$(printf '%s\n' "${NEW_RELEASE_BRANCHES[@]}" | awk '{printf "\"%s\",", $0}' | sed 's/,$/]/' | sed 's/^/[/' )" >> $GITHUB_OUTPUT

# Clean up temporary files
rm -f "$rancher_tags_file"