#!/usr/bin/env bash
# Builds Docker images of the services from the current main of their repositories:
#
#   make images IMAGE_TAG=local
#
# Images are tagged ghcr.io/pouw-zk/<repository>:$IMAGE_TAG and make uses them
# with the same IMAGE_TAG instead of :main from GHCR (e.g. make images test).
# NO_CACHE=1 builds from scratch, without Docker cache (evening build in Jenkins).
#
# A repository without a Dockerfile is skipped. The commits that were built
# are listed in build/versions.txt, the versions for staging (:sha-xxxxxxx
# images in GHCR, built by docker.yml from the same commits) in build/versions.env.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${IMAGE_TAG:?Set IMAGE_TAG, e.g. make images IMAGE_TAG=local}"
build="$root/build"
repos=(pouw-node pouw-indexer pouw-workload pouw-dashboard)

flags=(--pull)
[[ "${NO_CACHE:-}" == 1 ]] && flags+=(--no-cache)

mkdir -p "$build"
: >"$build/versions.txt"
: >"$build/versions.env"
for repo in "${repos[@]}"; do
    src="$build/src/$repo"
    rm -rf "$src"
    git clone -q --depth 1 "https://github.com/PoUW-ZK/$repo.git" "$src"
    sha="$(git -C "$src" rev-parse --short=7 HEAD)"
    if [[ ! -f "$src/Dockerfile" ]]; then
        echo "$repo $sha (no Dockerfile, skipped)" | tee -a "$build/versions.txt"
        continue
    fi
    docker build "${flags[@]}" \
        --label "org.opencontainers.image.revision=$sha" \
        -t "ghcr.io/pouw-zk/$repo:$tag" "$src"
    echo "$repo $sha" | tee -a "$build/versions.txt"
    echo "$(echo "${repo#pouw-}" | tr a-z A-Z)_VERSION=sha-$sha" >>"$build/versions.env"
done
