#!/bin/bash
set -Eeuo pipefail

mkdir -p /home/Sisyphus/Projects
cd /home/Sisyphus/Projects

while IFS=' ' read -r name url commit; do
    if [[ "$name" == schema=* || -z "$name" ]]; then
        continue
    fi
    
    # Check if we mapped it to a specific directory in the Makefile
    dir="$name"
    if [[ "$name" == "hermes" ]]; then dir="Hermes"; fi
    
    if [[ -d "$dir" ]]; then
        echo "Updating $dir..."
        cd "$dir"
        git fetch origin
        git checkout "$commit" || { git fetch origin "$commit"; git checkout "$commit"; }
        cd ..
    else
        echo "Cloning $dir..."
        mkdir -p "$dir"
        cd "$dir"
        git init
        git remote add origin "$url"
        # Deep clone is slow for linux.git, try shallow fetch for the specific commit
        git fetch --depth 1 origin "$commit"
        git checkout FETCH_HEAD
        cd ..
    fi
done < ArachOS/sources.lock
echo "All sources checked out."
