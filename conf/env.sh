#!/bin/sh

export PATH="$PATH:/usr/local/bin"
export TOPDIR="/home/gitlab-runner/fargate"

export AWS_ACCOUNT_ID="123456789012"

export AWS_ECS_CLUSTER="ecs-exec-demo-cluster"
export AWS_ECS_TASK_ROLE="ecs-exec-demo-task-role"
export AWS_ECS_TASK_EXECUTION_ROLE="ecs-exec-demo-task-execution-role"

export AWS_ECS_TASK_CPU="2048"
export AWS_ECS_TASK_MEM="4096"

export AWS_ECS_TASK_SUBNETS="subnet-0123456789abcdef1,subnet-0123456789abcdef2,subnet-0123456789abcdef3"
export AWS_ECS_TASK_SECURITY_GROUPS="sg-0123456789abcdef1"

export AWS_ECS_TASK_JSON="$TOPDIR/conf/task.json"

export GITLAB_RUNNER_SSH_KEY="$TOPDIR/conf/ssh/gitlab-runner"
export GITLAB_RUNNER_SSH_AUTHORIZED_KEYS="$(cat "${GITLAB_RUNNER_SSH_KEY}.pub")"

export GITLAB_RUNNER_LOGFILE="$TOPDIR/logs/fargate-$(date '+%Y.%m.%d').log"

export GITLAB_RUNNER_JOB_ID="${CUSTOM_ENV_CI_PROJECT_PATH_SLUG}-${CUSTOM_ENV_CI_PIPELINE_IID}-${CUSTOM_ENV_CI_JOB_ID}"
export GITLAB_RUNNER_JOB_DIR="$TOPDIR/run/$GITLAB_RUNNER_JOB_ID"

export GITLAB_RUNNER_CACHE_DIR="$TOPDIR/cache"

log() {
    DATE="$(date '+%H:%M:%S')"
    echo "$DATE INFO $GITLAB_RUNNER_SCRIPT $*"
    echo "$DATE INFO PROJECT=${CUSTOM_ENV_CI_PROJECT_PATH}, JOB=${CUSTOM_ENV_CI_JOB_NAME}, ID=${GITLAB_RUNNER_JOB_ID} $GITLAB_RUNNER_SCRIPT $*" >> "$GITLAB_RUNNER_LOGFILE"
}

error() {
    DATE="$(date '+%H:%M:%S')"
    echo "$DATE ERROR $GITLAB_RUNNER_SCRIPT $*" >&2
    echo "$DATE ERROR PROJECT=${CUSTOM_ENV_CI_PROJECT_PATH}, JOB=${CUSTOM_ENV_CI_JOB_NAME}, ID=${GITLAB_RUNNER_JOB_ID} $GITLAB_RUNNER_SCRIPT $*" >> "$GITLAB_RUNNER_LOGFILE"
}
