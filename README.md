# msi-terraform-cloudwatch-alarms

Reusable CloudWatch metric-alarm module for ECS, ALB, Lambda and EC2, with
enforced mandatory alerting tags. Built on top of
[`terraform-aws-modules/cloudwatch/aws//modules/metric-alarm`](https://registry.terraform.io/modules/terraform-aws-modules/cloudwatch/aws/latest/submodules/metric-alarm)
(pinned to `5.7.1`).

This module is one of a set of independently-versioned CloudWatch
observability modules (org: `MemberSolutionsInc`). Splitting alarm logic into
its own repo means bumping this module's version doesn't force a version
bump on sibling modules such as `msi-terraform-cloudwatch-composite-alarms`,
which consumes the `alarm_arns` output from this module.

## What it creates

| Resource group | Metric | Tiers |
| --- | --- | --- |
| ECS CPU utilization | `AWS/ECS` `CPUUtilization` | warn (>=70%, 10min) / crit (>=85%, 5min) |
| ECS memory utilization | `AWS/ECS` `MemoryUtilization` | warn (>=75%, 10min) / crit (>=90%, 5min) |
| ECS container restarts | `ECS/ContainerInsights` `RestartCount` | warn (>=3/10min) / crit (>=5/10min) |
| ALB 5xx errors | `AWS/ApplicationELB` `HTTPCode_ELB_5XX_Count` | warn / crit (configurable counts) |
| ALB latency | `AWS/ApplicationELB` `TargetResponseTime` (p95) | warn (>=1s) / crit (>=3s) |
| EC2 CPU utilization | `AWS/EC2` `CPUUtilization` (native, both OS) | warn (>=70%, 10min) / crit (>=85%, 5min) |
| EC2 memory utilization | `CWAgent` `mem_used_percent` (Linux) / `Memory % Committed Bytes In Use` (Windows) | warn (>=75%, 10min) / crit (>=90%, 5min) |
| EC2 disk usage | `CWAgent` `disk_used_percent` (Linux) / `LogicalDisk % Free Space` (Windows, inverted) | warn (>=75%) / crit (>=90%) |
| EC2 disk I/O wait | `CWAgent` `diskio_io_time` via metric math (Linux) / `PhysicalDisk % Disk Time` (Windows) | warn (>=20%) / crit (>=40%) |
| EC2 network interface errors | `CWAgent` `Packets Received/Outbound Errors` (Windows only) | warn / crit (configurable counts) |
| EC2 status check failed | `AWS/EC2` `StatusCheckFailed` | single tier |
| Lambda error rate | `AWS/Lambda` `Errors`/`Invocations` (metric math) | warn (>=1%) / crit (>=5%) |
| Lambda duration | `AWS/Lambda` `Duration` (p95, % of timeout) | warn (>=75%) / crit (>=90%) |
| Lambda throttles | `AWS/Lambda` `Throttles` | single tier |
| Lambda concurrent executions | `AWS/Lambda` `ConcurrentExecutions` (% of limit) | warn (>=80%) / crit (>=95%) |

All defaults reflect the org's CloudWatch monitoring standard and can be
overridden per-caller via the threshold variables in `variables.tf`.

### ALB 5xx thresholds are counts, not a rate

`HTTPCode_ELB_5XX_Count` is emitted upstream as a raw count metric, not a
rate, so `alb_5xx_warn_threshold_count` / `alb_5xx_crit_threshold_count` are
counts per evaluation window. Tune them per ALB traffic volume to approximate
the org's warn ~1% / crit ~5% error-rate guidance.

### EC2 memory/disk/disk-I/O/network-error alarms require the CloudWatch Agent

CPU utilization and status-check-failed are native `AWS/EC2` metrics and need
nothing extra. Memory, disk usage, disk I/O wait, and network interface
errors are all `CWAgent` metrics — the target instance needs
[`msi-terraform-cloudwatch-agent`](https://github.com/MemberSolutionsInc/msi-terraform-cloudwatch-agent)
(`>= v0.2.1`, for the `append_dimensions`/`drop_device` fixes) deployed with
a matching `os_type` first, or these alarms will sit in `INSUFFICIENT_DATA`
indefinitely. Each `ec2_instances` entry's `os_type` and `disk_resources`
must match what you passed to that instance's agent module invocation.

Linux and Windows disk/disk-I/O metrics use different underlying schemas and
some values (Linux disk `fstype`, Windows `PhysicalDisk` instance names,
Linux `diskio` device names) aren't knowable from Terraform ahead of time —
disk usage handles this with a `SEARCH()`-based metric query on Linux, and
disk I/O wait uses `MAX(SEARCH(...))` on both OSes to alarm on whichever
disk/device is busiest, rather than requiring an exact dimension match.

Network error alarms are Windows-only for now — `msi-terraform-cloudwatch-agent`
doesn't collect Linux network error counters yet. Setting
`enable_network_errors = true` on a Linux entry is a no-op (no alarm
created).

## Mandatory tagging

Every alarm resource is tagged with the `tags` map you pass in, which **must**
contain non-empty values for `service`, `env`, `severity`, `team`, and
`runbook` — this is enforced by a `validation` block on `var.tags` and will
fail `terraform plan`/`apply` otherwise.

For alarm pairs where this module distinguishes a warning tier from a
critical tier, the `severity` key is overridden per-alarm (`warning` /
`critical`) regardless of what you passed in `var.tags`. Single-tier alarms
(EC2 status check, Lambda throttles) use your `severity` value unmodified.

## Usage

```hcl
module "cloudwatch_alarms" {
  source = "git::https://github.com/MemberSolutionsInc/msi-terraform-cloudwatch-alarms.git?ref=v0.1.0"

  tags = {
    service = "checkout-api"
    env     = "prod"
    severity = "warning" # overridden per-alarm for warn/crit tiers
    team     = "platform-eng"
    runbook  = "https://wiki.example.com/runbooks/checkout-api"
  }

  sns_topic_arns = {
    critical_alarm_arn = aws_sns_topic.crit_alert.arn
    critical_ok_arn    = aws_sns_topic.crit_alert_ok.arn
    warning_alarm_arn  = aws_sns_topic.warn_alert.arn
    warning_ok_arn     = aws_sns_topic.warn_alert_ok.arn
  }

  ecs_clusters = {
    checkout = {
      create       = true
      cluster_name = "prod-ecs-cluster-checkout"
      services     = ["checkout-api", "checkout-worker"]
    }
  }

  albs = {
    checkout = {
      name = "app/prod-checkout-alb/1234567890abcdef"
    }
  }

  ec2_instances = {
    checkout_host = {
      instance_id    = "i-0123456789abcdef0"
      os_type        = "linux"
      disk_resources = ["/", "/data"]
    }
    app3_prod_d = {
      instance_id            = "i-0fad170ef80facf91"
      os_type                = "windows"
      disk_resources         = ["C:"]
      enable_network_errors  = true
    }
  }

  lambda_functions = {
    image_resize = {
      function_name     = "prod-image-resize"
      timeout_seconds   = 30
      concurrency_limit = 50
    }
  }
}
```

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | --- |
| `tags` | Mandatory tags (service, env, severity, team, runbook) applied to every alarm | `map(string)` | n/a | yes |
| `sns_topic_arns` | SNS topic ARNs for alarm/OK actions by severity | `object` | n/a | yes |
| `ecs_clusters` | ECS clusters/services to monitor | `map(object)` | n/a | yes |
| `albs` | ALBs to monitor | `map(object)` | n/a | yes |
| `ec2_instances` | EC2 instances to monitor (instance_id, os_type, disk_resources, enable_memory/diskio/network_errors) | `map(object)` | `{}` | no |
| `lambda_functions` | Lambda functions to monitor | `map(object)` | n/a | yes |
| `ecs_cpu_warn_threshold_percent` | ECS CPU warn threshold | `number` | `70` | no |
| `ecs_cpu_warn_evaluation_minutes` | ECS CPU warn evaluation window (minutes) | `number` | `10` | no |
| `ecs_cpu_crit_threshold_percent` | ECS CPU crit threshold | `number` | `85` | no |
| `ecs_cpu_crit_evaluation_minutes` | ECS CPU crit evaluation window (minutes) | `number` | `5` | no |
| `ecs_memory_warn_threshold_percent` | ECS memory warn threshold | `number` | `75` | no |
| `ecs_memory_warn_evaluation_minutes` | ECS memory warn evaluation window (minutes) | `number` | `10` | no |
| `ecs_memory_crit_threshold_percent` | ECS memory crit threshold | `number` | `90` | no |
| `ecs_memory_crit_evaluation_minutes` | ECS memory crit evaluation window (minutes) | `number` | `5` | no |
| `ecs_container_restart_period_seconds` | Container restart evaluation window (seconds) | `number` | `600` | no |
| `ecs_container_restart_warn_threshold` | Container restart warn threshold (count) | `number` | `3` | no |
| `ecs_container_restart_crit_threshold` | Container restart crit threshold (count) | `number` | `5` | no |
| `alb_5xx_period_seconds` | ALB 5xx evaluation window (seconds) | `number` | `300` | no |
| `alb_5xx_evaluation_periods` | ALB 5xx number of periods | `number` | `2` | no |
| `alb_5xx_warn_threshold_count` | ALB 5xx warn threshold (count) | `number` | `10` | no |
| `alb_5xx_crit_threshold_count` | ALB 5xx crit threshold (count) | `number` | `25` | no |
| `alb_latency_period_seconds` | ALB latency evaluation window (seconds) | `number` | `60` | no |
| `alb_latency_evaluation_periods` | ALB latency number of periods | `number` | `5` | no |
| `alb_latency_warn_threshold_seconds` | ALB p95 latency warn threshold (seconds) | `number` | `1` | no |
| `alb_latency_crit_threshold_seconds` | ALB p95 latency crit threshold (seconds) | `number` | `3` | no |
| `ec2_cpu_warn_threshold_percent` | EC2 CPU warn threshold | `number` | `70` | no |
| `ec2_cpu_warn_evaluation_minutes` | EC2 CPU warn evaluation window (minutes) | `number` | `10` | no |
| `ec2_cpu_crit_threshold_percent` | EC2 CPU crit threshold | `number` | `85` | no |
| `ec2_cpu_crit_evaluation_minutes` | EC2 CPU crit evaluation window (minutes) | `number` | `5` | no |
| `ec2_memory_warn_threshold_percent` | EC2 memory warn threshold | `number` | `75` | no |
| `ec2_memory_warn_evaluation_minutes` | EC2 memory warn evaluation window (minutes) | `number` | `10` | no |
| `ec2_memory_crit_threshold_percent` | EC2 memory crit threshold | `number` | `90` | no |
| `ec2_memory_crit_evaluation_minutes` | EC2 memory crit evaluation window (minutes) | `number` | `5` | no |
| `ec2_disk_warn_threshold_percent` | EC2 disk usage warn threshold (used %) | `number` | `75` | no |
| `ec2_disk_warn_evaluation_periods` | EC2 disk usage warn number of periods | `number` | `5` | no |
| `ec2_disk_crit_threshold_percent` | EC2 disk usage crit threshold (used %) | `number` | `90` | no |
| `ec2_disk_crit_evaluation_periods` | EC2 disk usage crit number of periods | `number` | `3` | no |
| `ec2_disk_period_seconds` | EC2 disk usage evaluation window (seconds) | `number` | `60` | no |
| `ec2_diskio_warn_threshold_percent` | EC2 disk I/O wait warn threshold (%) | `number` | `20` | no |
| `ec2_diskio_crit_threshold_percent` | EC2 disk I/O wait crit threshold (%) | `number` | `40` | no |
| `ec2_diskio_period_seconds` | EC2 disk I/O wait evaluation window (seconds) | `number` | `60` | no |
| `ec2_diskio_evaluation_periods` | EC2 disk I/O wait number of periods | `number` | `5` | no |
| `ec2_network_errors_period_seconds` | EC2 network errors evaluation window (seconds) | `number` | `300` | no |
| `ec2_network_errors_evaluation_periods` | EC2 network errors number of periods | `number` | `2` | no |
| `ec2_network_errors_warn_threshold_count` | EC2 network errors warn threshold (count) | `number` | `1` | no |
| `ec2_network_errors_crit_threshold_count` | EC2 network errors crit threshold (count) | `number` | `10` | no |
| `ec2_status_check_period_seconds` | EC2 status check evaluation window (seconds) | `number` | `60` | no |
| `ec2_status_check_evaluation_periods` | EC2 status check number of periods | `number` | `2` | no |
| `lambda_error_rate_period_seconds` | Lambda error rate evaluation window (seconds) | `number` | `300` | no |
| `lambda_error_rate_evaluation_periods` | Lambda error rate number of periods | `number` | `1` | no |
| `lambda_error_rate_warn_percent` | Lambda error rate warn threshold (%) | `number` | `1` | no |
| `lambda_error_rate_crit_percent` | Lambda error rate crit threshold (%) | `number` | `5` | no |
| `lambda_duration_period_seconds` | Lambda duration evaluation window (seconds) | `number` | `300` | no |
| `lambda_duration_evaluation_periods` | Lambda duration number of periods | `number` | `1` | no |
| `lambda_duration_warn_percent_of_timeout` | Lambda p95 duration warn threshold (% of timeout) | `number` | `75` | no |
| `lambda_duration_crit_percent_of_timeout` | Lambda p95 duration crit threshold (% of timeout) | `number` | `90` | no |
| `lambda_throttle_period_seconds` | Lambda throttle evaluation window (seconds) | `number` | `300` | no |
| `lambda_throttle_evaluation_periods` | Lambda throttle number of periods | `number` | `1` | no |
| `lambda_throttle_threshold` | Lambda throttle threshold (count) | `number` | `1` | no |
| `lambda_concurrency_period_seconds` | Lambda concurrency evaluation window (seconds) | `number` | `60` | no |
| `lambda_concurrency_evaluation_periods` | Lambda concurrency number of periods | `number` | `5` | no |
| `lambda_concurrency_warn_percent` | Lambda concurrency warn threshold (% of limit) | `number` | `80` | no |
| `lambda_concurrency_crit_percent` | Lambda concurrency crit threshold (% of limit) | `number` | `95` | no |

## Outputs

| Name | Description |
| --- | --- |
| `alarm_arns` | Map of every CloudWatch alarm ARN created by this module, keyed by a unique alarm identifier (`<category>-<tier>-<resource-key>`). Consumed by `msi-terraform-cloudwatch-composite-alarms`. |

## Versioning

This repo is independently versioned (semver tags, e.g. `v0.1.0`). Pin the
`ref` in the `source` URL to a specific tag in consuming code; do not track
`main`.
