#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_root="$(cd -- "${script_dir}/.." && pwd)"
test_image=xingchen-legacy-bash-test

docker build -f "${script_dir}/legacy-bash-test.Dockerfile" -t "${test_image}" "${project_root}"
for suite in install-agent xingchen install-controller bootstrap-controller-update update-controller; do
  printf '\nTesting %s with Bash 4.2\n' "${suite}"
  docker run --rm --network none --memory 768m --cpus 1 --pids-limit 256 \
    --mount "type=bind,src=${project_root},dst=/workspace,readonly" \
    "${test_image}" "deploy/${suite}_test.sh"
done
