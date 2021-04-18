#!/bin/bash

set -eu

export GITLAB_RUNNER_SCRIPT="prepare"

source "$(dirname "${0}")/../conf/env.sh"

if [[ -d "${GITLAB_RUNNER_JOB_DIR}" ]]; then
    mv "${GITLAB_RUNNER_JOB_DIR}" "${GITLAB_RUNNER_JOB_DIR}.$(date '+%Y%m%d%h%m%s')"
fi

mkdir "${GITLAB_RUNNER_JOB_DIR}"

cd "${GITLAB_RUNNER_JOB_DIR}"

env -u CUSTOM_ENV_CI_SERVER_TLS_CA_FILE env | sort > "${GITLAB_RUNNER_SCRIPT}.env"

envsubst < "${AWS_ECS_TASK_JSON}" > "task.json"

if [[ "${CUSTOM_ENV_CI_JOB_IMAGE_ENTRYPOINT:-}" != "" ]]; then
    jq \
        --arg entryPoint "${CUSTOM_ENV_CI_JOB_IMAGE_ENTRYPOINT}" \
        '(.containerDefinitions[] | select(.name == "gitlab-job")) += {entryPoint: [$entryPoint]}' "task.json" > "task.json.tmp"
    mv -f "task.json.tmp" "task.json"
fi

if ! aws ecs register-task-definition --output json --cli-input-json "file://task.json" \
    > "register-task.json" |& tee "register-task.err"
then
    error "Cannot register ecs task"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
fi

AWS_ECS_TASK_DEFINITION_STATUS="$(jq -r '.taskDefinition.status' "register-task.json")"
if [ "${AWS_ECS_TASK_DEFINITION_STATUS}" != "ACTIVE" ]; then
    error "Cannot register task definition, taskDefinition.status: ${AWS_ECS_TASK_DEFINITION_STATUS}"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
fi

if ! aws ecs run-task --output json --cluster "${AWS_ECS_CLUSTER}" --launch-type "FARGATE" --platform-version "1.4.0" --enable-execute-command \
        --task-definition "${GITLAB_RUNNER_JOB_ID}" --network-configuration awsvpcConfiguration="{subnets=[${AWS_ECS_TASK_SUBNETS}],securityGroups=[${AWS_ECS_TASK_SECURITY_GROUPS}]}" \
        > "run-task.json" |& tee "run-task.err"
then
    error "Cannot run ecs task"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
fi

AWS_ECS_TASK_ARN="$(jq -r '.tasks[0].taskArn' "run-task.json")"

log "ECS Task ID: ${AWS_ECS_TASK_ARN##*/}"

for retry in $(seq -w 30); do

    if ! aws ecs describe-tasks --output json --cluster "${AWS_ECS_CLUSTER}" --tasks "${AWS_ECS_TASK_ARN}" \
        > "describe-task.json" |& tee "describe-task.err"
    then
        error "Cannot describe ecs task"
        exit "${SYSTEM_FAILURE_EXIT_CODE}"
    fi

    AWS_ECS_RUNNER_AGENT_STATUS="$(jq -r '.tasks[0].containers[] | select(.name == "gitlab-runner").managedAgents[] | select(.name == "ExecuteCommandAgent").lastStatus' "describe-task.json")"

    if [[ "${AWS_ECS_RUNNER_AGENT_STATUS}" == "PENDING" ]]; then
        log "gitlab-runner agent status: ${AWS_ECS_RUNNER_AGENT_STATUS} (retry=${retry})"
        sleep 5
        continue
    fi

    if [[ "${AWS_ECS_RUNNER_AGENT_STATUS}" == "RUNNING" ]]; then
        log "gitlab-runner agent status: ${AWS_ECS_RUNNER_AGENT_STATUS} (retry=${retry})"
        break
    fi

    error "gitlab-runner agent status: ${AWS_ECS_RUNNER_AGENT_STATUS} (retry=${retry})"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
done

log "gitlab-runner: prepare container"
if ! aws ecs execute-command \
        --cluster "${AWS_ECS_CLUSTER}" --task "${AWS_ECS_TASK_ARN}" \
        --container gitlab-runner --interactive --command "/bin/sh -c ' \
            apk add --no-cache rsync openssh-server \
            && rsync --archive --hard-links --one-file-system --stats /bin /lib /sbin /usr /mnt/runner/ \
            && mkdir -p /root/.ssh \
            && echo \"${GITLAB_RUNNER_SSH_AUTHORIZED_KEYS}\" > /root/.ssh/authorized_keys \
            && sed -i.bak \"s/^root:!/root:*/\" /etc/shadow \
            && ssh-keygen -A \
            && mkdir /mnt/runner/log \
            && /usr/sbin/sshd -E /mnt/runner/log/sshd.log \
            && mkdir /mnt/tmp \
            && touch /mnt/ready'" \
        > "exec-task-runner.out" |& tee "exec-task-runner.err"
then
    error "Cannot execute command in gitlab-runner container"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
fi

for retry in $(seq -w 30); do

    if ! aws ecs describe-tasks --output json --cluster "${AWS_ECS_CLUSTER}" --tasks "${AWS_ECS_TASK_ARN}" \
        > "describe-task.json" |& tee "describe-task.err"
    then
        error "Cannot describe ecs task"
        exit "${SYSTEM_FAILURE_EXIT_CODE}"
    fi

    AWS_ECS_RUNNER_HEALTH_STATUS="$(jq -r '.tasks[0].containers[] | select(.name == "gitlab-runner").healthStatus' "describe-task.json")"

    if [[ "${AWS_ECS_RUNNER_HEALTH_STATUS}" == "UNKNOWN" ]]; then
        log "gitlab-runner health status: ${AWS_ECS_RUNNER_HEALTH_STATUS} (retry=${retry})"
        sleep 5
        continue
    fi

    if [[ "${AWS_ECS_RUNNER_HEALTH_STATUS}" == "HEALTHY" ]]; then
        log "gitlab-runner health status: ${AWS_ECS_RUNNER_HEALTH_STATUS} (retry=${retry})"
        break
    fi

    error "gitlab-runner health status: ${AWS_ECS_RUNNER_HEALTH_STATUS}"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
done

for retry in $(seq -w 30); do

    if ! aws ecs describe-tasks --output json --cluster "${AWS_ECS_CLUSTER}" --tasks "${AWS_ECS_TASK_ARN}" \
        > "describe-task.json" |& tee "describe-task.err"
    then
        error "Cannot describe ecs task"
        exit "${SYSTEM_FAILURE_EXIT_CODE}"
    fi

    AWS_ECS_JOB_HEALTH_STATUS="$(jq -r '.tasks[0].containers[] | select(.name == "gitlab-job").healthStatus' "describe-task.json")"

    if [[ "${AWS_ECS_JOB_HEALTH_STATUS}" == "UNKNOWN" ]]; then
        log "gitlab-job health status: ${AWS_ECS_JOB_HEALTH_STATUS} (retry=${retry})"
        sleep 5
        continue
    fi

    if [[ "${AWS_ECS_JOB_HEALTH_STATUS}" == "HEALTHY" ]]; then
        log "gitlab-job health status: ${AWS_ECS_JOB_HEALTH_STATUS} (retry=${retry})"
        break
    fi

    error "gitlab-job health status: ${AWS_ECS_JOB_HEALTH_STATUS}"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
done

for retry in $(seq -w 30); do

    if ! aws ecs describe-tasks --output json --cluster "${AWS_ECS_CLUSTER}" --tasks "${AWS_ECS_TASK_ARN}" \
        > "describe-task.json" |& tee "describe-task.err"
    then
        error "Cannot describe ecs task"
        exit "${SYSTEM_FAILURE_EXIT_CODE}"
    fi

    AWS_ECS_TASK_HEALTH_STATUS="$(jq -r '.tasks[0].healthStatus' "describe-task.json")"

    if [[ "${AWS_ECS_TASK_HEALTH_STATUS}" == "UNKNOWN" ]]; then
        log "ecs task health status: ${AWS_ECS_TASK_HEALTH_STATUS} (retry=${retry})"
        sleep 5
        continue
    fi

    if [[ "${AWS_ECS_TASK_HEALTH_STATUS}" == "HEALTHY" ]]; then
        log "ecs task health status: ${AWS_ECS_TASK_HEALTH_STATUS} (retry=${retry})"
        break
    fi

    error "ecs task health status: ${AWS_ECS_TASK_HEALTH_STATUS}"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
done

log "gitlab-runner agent status: $(jq -r '.tasks[0].containers[] | select(.name == "gitlab-runner").managedAgents[] | select(.name == "ExecuteCommandAgent").lastStatus' "describe-task.json")"
log "gitlab-runner health status: $(jq -r '.tasks[0].containers[] | select(.name == "gitlab-runner").healthStatus' "describe-task.json")"

log "gitlab-job agent status: $(jq -r '.tasks[0].containers[] | select(.name == "gitlab-job").managedAgents[] | select(.name == "ExecuteCommandAgent").lastStatus' "describe-task.json")"
log "gitlab-job health status: $(jq -r '.tasks[0].containers[] | select(.name == "gitlab-job").healthStatus' "describe-task.json")"

AWS_ECS_RUNNER_IP="$(jq -r '.tasks[0].containers[] | select(.name == "gitlab-runner").networkInterfaces[0].privateIpv4Address' "describe-task.json")"

log "ECS Task IP: ${AWS_ECS_RUNNER_IP}"

if ! ssh -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null -i "${GITLAB_RUNNER_SSH_KEY}" -l "root" "${AWS_ECS_RUNNER_IP}" "echo ok" \
    > /dev/null |& tee prepare-ssh.err
then
    error "Cannot ssh to gitlab-runner"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
fi

log "gitlab-runner: ssh OK"

if ! aws ecs execute-command \
        --output json --cluster "${AWS_ECS_CLUSTER}" --task "${AWS_ECS_TASK_ARN}" \
        --container gitlab-job --interactive --command "/bin/sh -c 'echo ok'" \
        > "exec-task-job.out" |& tee "exec-task-job.err"
then
    error "Cannot execute command in gitlab-job container"
    exit "${SYSTEM_FAILURE_EXIT_CODE}"
fi

log "gitlab-job: exec ok"

log "ready"

exit 0
