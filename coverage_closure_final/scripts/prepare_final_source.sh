#!/bin/bash
set -euo pipefail
if [[ $# != 3 ]]; then
    echo "usage: $0 FROZEN_SOURCE_ARCHIVE PATCH NEW_SOURCE_DIR" >&2
    exit 2
fi
archive=$(realpath "$1")
patch_file=$(realpath "$2")
dir=$3
mkdir "$dir"
tar -xzf "$archive" -C "$dir"
cd "$dir"
export GIT_CEILING_DIRECTORIES
GIT_CEILING_DIRECTORIES=$(dirname "$PWD")
git apply --no-index --check "$patch_file"
git apply --no-index "$patch_file"
