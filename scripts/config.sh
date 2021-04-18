#!/bin/bash

set -eu

export GITLAB_RUNNER_SCRIPT="config"

source "$(dirname "${0}")/../conf/env.sh"

log 'driver: [name="fargate", version="v0.1.0"]' > /dev/null

cat << EOS
{
  "driver": {
    "name": "fargate",
    "version": "v0.1.0"
  },
  "builds_dir_is_shared": false,
  "cache_dir": "/mnt/cache",
  "builds_dir": "/mnt/builds"
}
EOS

exit 0
