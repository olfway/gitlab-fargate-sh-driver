#!/bin/bash

set -eu

export GITLAB_RUNNER_STAGE="${2}"
export GITLAB_RUNNER_SCRIPT_FILE="${1}"

export GITLAB_RUNNER_SCRIPT="run-${GITLAB_RUNNER_STAGE}"

source "$(dirname "${0}")/../conf/env.sh"

cd "${GITLAB_RUNNER_JOB_DIR}"

cat "${GITLAB_RUNNER_SCRIPT_FILE}" > "${GITLAB_RUNNER_SCRIPT}.sh"

env -u CUSTOM_ENV_CI_SERVER_TLS_CA_FILE env | sort > "${GITLAB_RUNNER_SCRIPT}.env"

if [[ ! -s "describe-task.json" ]]; then
    error "Running task not found"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
fi

AWS_ECS_TASK_ARN="$(jq -r '.tasks[0].taskArn' "describe-task.json")"
AWS_ECS_RUNNER_IP="$(jq -r '.tasks[0].containers[] | select(.name == "gitlab-runner").networkInterfaces[0].privateIpv4Address' "describe-task.json")"

log "scp script file to gitlab-runner"

if ! scp -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -i "${GITLAB_RUNNER_SSH_KEY}" \
        "${GITLAB_RUNNER_SCRIPT_FILE}" "root@${AWS_ECS_RUNNER_IP}:/mnt/tmp/${GITLAB_RUNNER_STAGE}.sh" \
    |& tee "${GITLAB_RUNNER_SCRIPT}-scp.log"
then
    error "Cannot copy ${GITLAB_RUNNER_STAGE} script to gitlub-runner"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
fi

if [[ "${GITLAB_RUNNER_STAGE}" =~ (build_script|step_script|after_script) ]]; then
    log "Running ${GITLAB_RUNNER_STAGE} script in gitlab-job container"

    if ! unbuffer aws ecs execute-command \
        --cluster "${AWS_ECS_CLUSTER}" --task "${AWS_ECS_TASK_ARN}" --container "gitlab-job" --interactive \
        --command "/bin/sh -c '/mnt/tmp/${GITLAB_RUNNER_STAGE}.sh 2>&1 || rc=\$?; echo ExitCode: \${rc:-0}; exit 0'" \
        |& tee "${GITLAB_RUNNER_SCRIPT}-exec.log"
    then
        error "Cannot execute command in gitlab-job container"
        exit "${SYSTEM_FAILURE_EXIT_CODE}"
    fi

    if grep -q 'ExecuteCommand operation: The execute command failed' "${GITLAB_RUNNER_SCRIPT}-exec.log"; then
        error "Cannot execute command in gitlab-job container"
        exit "${SYSTEM_FAILURE_EXIT_CODE}"
    fi

    log "Getting ${GITLAB_RUNNER_STAGE} script exit code"

    GITLAB_RUNNER_SCRIPT_RC="$(tac "${GITLAB_RUNNER_SCRIPT}-exec.log" | awk '/^ExitCode: / { print $2; exit; }' | tr -d "\r")"
    log "Exit code: ${GITLAB_RUNNER_SCRIPT_RC}"

    if [[ "${GITLAB_RUNNER_SCRIPT_RC}" == "0" ]]; then
        exit 0
    else
        exit "${BUILD_FAILURE_EXIT_CODE}"
    fi
fi

if [[ "${GITLAB_RUNNER_STAGE}" == "restore_cache" ]] \
   && [[ -d "${GITLAB_RUNNER_CACHE_DIR}/${CUSTOM_ENV_CI_PROJECT_PATH}" ]]
then
    log "Getting list of cache files"
    if ! cat "${GITLAB_RUNNER_SCRIPT}.sh" \
        | sed -E 's/\\n/\n/g' \
        | grep -E "gitlab-runner.+cache-extractor.+--file.+cache/${CUSTOM_ENV_CI_PROJECT_PATH}/" \
        | grep -E -o "${CUSTOM_ENV_CI_PROJECT_PATH}/[^\"]+" \
        | tee "${GITLAB_RUNNER_SCRIPT}.files"
    then
        error "Cannot get list of files"
    else
        log "Uploading cache to fargate volume"
        if ! rsync -av \
            --rsh="ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -i '${GITLAB_RUNNER_SSH_KEY}' -l 'root'" \
            --files-from="${GITLAB_RUNNER_SCRIPT}.files" \
            "${GITLAB_RUNNER_CACHE_DIR}" "${AWS_ECS_RUNNER_IP}:/mnt/cache/"
        then
            error "Cannot upload files"
        fi
    fi
fi

log "Running ${GITLAB_RUNNER_STAGE} script in gitlab-runner container"

if ! ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -i "${GITLAB_RUNNER_SSH_KEY}" \
    -l "root" "${AWS_ECS_RUNNER_IP}" "/mnt/tmp/${GITLAB_RUNNER_STAGE}.sh 2>&1 || rc=\$?; echo ExitCode: \${rc:-0}; exit 0" \
    |& tee "${GITLAB_RUNNER_SCRIPT}-ssh.log"
then
    error "Cannot ssh into gitlab-runner"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
fi

log "Getting ${GITLAB_RUNNER_STAGE} script exit code"

GITLAB_RUNNER_SCRIPT_RC="$(tac "${GITLAB_RUNNER_SCRIPT}-ssh.log" | awk '/^ExitCode: / { print $2; exit; }' | tr -d "\r")"
log "Exit code: ${GITLAB_RUNNER_SCRIPT_RC}"

if [[ "${GITLAB_RUNNER_SCRIPT_RC}" != "0" ]]; then
    exit "${BUILD_FAILURE_EXIT_CODE}"
fi

if [[ "${GITLAB_RUNNER_STAGE}" == "archive_cache" ]]; then
    log "Downloading cache files from fargate volume"
    if ! rsync -av --whole-file \
        --rsh="ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -i '${GITLAB_RUNNER_SSH_KEY}' -l 'root'" \
        "${AWS_ECS_RUNNER_IP}:/mnt/cache/" "${GITLAB_RUNNER_CACHE_DIR}/"
    then
        error "Cannot download files"
    fi
fi

exit 0

