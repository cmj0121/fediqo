#!/usr/bin/env bash
# A Docker daemon this job can use, or a hard failure.
#
# GitHub's macos-15 runner has no Docker Desktop. Nested virt for colima is
# often missing on the ARM image. Trying and then failing closed is the honest
# answer: a green job that never brought the servers up would mean nothing.

set -euo pipefail

if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "ci-docker: docker is already running"
    docker info | sed -n 's/^/  /p' | head -n 20
    exit 0
fi

echo "ci-docker: no Docker daemon. Trying colima."

if ! command -v brew >/dev/null 2>&1; then
    echo >&2 "ci-docker: brew is not on PATH; cannot install colima. Fail closed."
    exit 1
fi

if ! command -v colima >/dev/null 2>&1 || ! command -v docker >/dev/null 2>&1; then
    brew install docker colima || {
        echo >&2 "ci-docker: brew could not install docker/colima. Fail closed."
        exit 1
    }
fi

colima start --cpu 3 --memory 7 --disk 40 --runtime docker || {
    echo >&2 "ci-docker: colima could not start (macos-15 ARM often cannot nest a VM)."
    echo >&2 "Fail closed: this job must not be green without the servers."
    exit 1
}

docker info >/dev/null 2>&1 || {
    echo >&2 "ci-docker: colima started but docker info still fails. Fail closed."
    exit 1
}

echo "ci-docker: colima brought a Docker daemon up"
