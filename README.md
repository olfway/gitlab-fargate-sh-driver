## Gitlab fargate.sh driver

### Shell-based fargate driver for custom executor

Proof of concept implementation based on aws ecs execute-command \
https://aws.amazon.com/blogs/containers/new-using-amazon-ecs-exec-access-your-containers-fargate-ec2/

### Runner configuration

```
[[runners]]
  name = "gitlab-fargate-runner"
  url = "https://gitlab.example.com"
  token = "p_XXXXXXXXXXXXXX-XXX"
  executor = "custom"
  shell = "sh"
  cache_dir = "/home/gitlab-runner/fargate/cache"
  builds_dir = "/home/gitlab-runner/fargate/builds"
  [runners.custom]
    config_exec = "/home/gitlab-runner/fargate/scripts/config.sh"
    prepare_exec = "/home/gitlab-runner/fargate/scripts/prepare.sh"
    run_exec = "/home/gitlab-runner/fargate/scripts/run.sh"
    cleanup_exec = "/home/gitlab-runner/fargate/scripts/cleanup.sh"
```
