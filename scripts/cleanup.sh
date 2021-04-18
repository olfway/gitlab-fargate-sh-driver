#!/bin/bash

set -eu

export GITLAB_RUNNER_SCRIPT="cleanup"

source "$(dirname "${0}")/../conf/env.sh"

cd "${GITLAB_RUNNER_JOB_DIR}"

env -u CUSTOM_ENV_CI_SERVER_TLS_CA_FILE env | sort > "${GITLAB_RUNNER_SCRIPT}.env"

if [[ -s "run-task.json" ]]; then
    AWS_ECS_TASK_ARN="$(jq -r '.tasks[0].taskArn' "run-task.json")"
    log "stop task: ${AWS_ECS_TASK_ARN##*/}"
    if ! aws ecs stop-task --output json --cluster "${AWS_ECS_CLUSTER}" --task "${AWS_ECS_TASK_ARN}" \
        > "stop-task.json" |& tee "stop-task.err"
    then
        error "Cannot stop ecs task: ${AWS_ECS_TASK_ARN}"
    fi
fi

if [[ -s "register-task.json" ]]; then
    AWS_ECS_TASK_DEFINITION_ARN="$(jq -r '.taskDefinition.taskDefinitionArn'  "register-task.json")"
    log "deregister task definition: ${AWS_ECS_TASK_DEFINITION_ARN##*/}"
    if ! aws ecs deregister-task-definition --output json --task-definition "${AWS_ECS_TASK_DEFINITION_ARN}" \
        > "deregister-task-definition.json" |& tee "deregister-task-definition.err"
    then
        error "Cannot deregister task definition: ${AWS_ECS_TASK_DEFINITION_ARN}"
    fi
fi

cd /

if [[ "${CUSTOM_ENV_CI_JOB_STATUS}" == "success" ]]; then
    log "remove temporary dir: ${GITLAB_RUNNER_JOB_DIR}"
    rm -rf "${GITLAB_RUNNER_JOB_DIR}"
fi

log "done"

exit 0
