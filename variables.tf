###############################################################################
# Mandatory tagging
###############################################################################

variable "tags" {
  description = <<-EOT
    Mandatory tags applied to every alarm created by this module. Must contain
    non-empty values for: service, env, severity, team, runbook.

    Note: for alarm pairs where this module distinguishes a warning tier from
    a critical tier (e.g. CPU, memory, container restarts, ALB 5xx, ALB
    latency, Lambda error rate, Lambda duration, Lambda concurrency), the
    `severity` key you pass here is overridden per-alarm to "warning" or
    "critical" as appropriate. Single-tier alarms (EC2 status check, Lambda
    throttles) use the `severity` value you pass through unmodified.
  EOT
  type        = map(string)

  validation {
    condition = alltrue([
      for k in ["service", "env", "severity", "team", "runbook"] :
      contains(keys(var.tags), k) && trimspace(lookup(var.tags, k, "")) != ""
    ])
    error_message = "var.tags must include non-empty values for: service, env, severity, team, runbook."
  }
}

###############################################################################
# Notification targets
###############################################################################

variable "sns_topic_arns" {
  description = "SNS topic ARNs used for alarm notification (ALARM/OK) actions, by severity."
  type = object({
    critical_alarm_arn = string
    critical_ok_arn    = string
    warning_alarm_arn  = string
    warning_ok_arn     = string
  })
}

###############################################################################
# ECS inputs
###############################################################################

variable "ecs_clusters" {
  description = <<-EOT
    Map of ECS clusters to monitor, keyed by an arbitrary identifier.
    `cluster_name` is the actual ECS ClusterName CloudWatch dimension value
    (not a naming-convention prefix), and `services` lists the ECS service
    names running in that cluster that should get CPU/memory/restart alarms.
    Set `create = false` to skip a cluster without removing it from the map.
  EOT
  type = map(object({
    create       = bool
    cluster_name = string
    services     = list(string)
  }))
}

###############################################################################
# ALB inputs
###############################################################################

variable "albs" {
  description = <<-EOT
    Map of Application Load Balancers to monitor, keyed by an arbitrary
    identifier. `name` must be the ALB's CloudWatch dimension value (the
    `app/<alb-name>/<id>` suffix of the ALB's ARN).
  EOT
  type = map(object({
    name = string
  }))
}

###############################################################################
# EC2 inputs
###############################################################################

variable "ec2_instances" {
  description = <<-EOT
    Map of EC2 instances to monitor, keyed by an arbitrary identifier.

    - `instance_id`: the EC2 InstanceId CloudWatch dimension value. Always
      gets CPU utilization and status-check-failed alarms (both native
      AWS/EC2 metrics, no CloudWatch Agent required).
    - `os_type` (`"linux"` or `"windows"`): selects the CWAgent metric name
      used for memory. Must match the `os_type` passed to this same
      instance's msi-terraform-cloudwatch-agent invocation.
    - `disk_resources`: Windows drive letters to alarm disk usage on (e.g.
      `["C:"]`) — must match that instance's `windows_disk_resources` in the
      agent module. Ignored on Linux (CloudWatch alarms can't use SEARCH(),
      so there's no way to alarm on Linux's unpredictable `fstype`
      dimension — see README).
    - `enable_memory`: gates the memory alarm (works on both OSes).
      `enable_diskio`: gates the disk-I/O-wait alarm — Windows only (see
      README), ignored on Linux. Both default `true`.
    - `enable_network_errors`: gates the network-error-counter alarm.
      Windows only for now — msi-terraform-cloudwatch-agent doesn't collect
      Linux network error counters yet, so this is ignored (no alarm
      created) when `os_type = "linux"`. Default `true`.
  EOT
  type = map(object({
    instance_id           = string
    os_type               = string
    disk_resources        = optional(list(string), [])
    enable_memory         = optional(bool, true)
    enable_diskio         = optional(bool, true)
    enable_network_errors = optional(bool, true)
  }))
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.ec2_instances : contains(["linux", "windows"], v.os_type)
    ])
    error_message = "Every ec2_instances entry's os_type must be \"linux\" or \"windows\"."
  }
}

###############################################################################
# Lambda inputs
###############################################################################

variable "lambda_functions" {
  description = <<-EOT
    Map of Lambda functions to monitor, keyed by an arbitrary identifier.
    `timeout_seconds` must match the function's configured timeout (used to
    compute duration alarm thresholds as a percentage of timeout).
    `concurrency_limit` is the reserved concurrency (or account/region
    concurrency limit the function effectively shares) used to compute
    concurrent-executions alarm thresholds as a percentage of that limit.
  EOT
  type = map(object({
    function_name     = string
    timeout_seconds   = number
    concurrency_limit = number
  }))
}

###############################################################################
# Threshold configuration - ECS CPU utilization
###############################################################################

variable "ecs_cpu_warn_threshold_percent" {
  description = "ECS service CPU utilization percent at which the warning alarm triggers."
  type        = number
  default     = 70
}

variable "ecs_cpu_warn_evaluation_minutes" {
  description = "Number of consecutive 1-minute periods CPU must stay above the warning threshold before alarming."
  type        = number
  default     = 10
}

variable "ecs_cpu_crit_threshold_percent" {
  description = "ECS service CPU utilization percent at which the critical alarm triggers."
  type        = number
  default     = 85
}

variable "ecs_cpu_crit_evaluation_minutes" {
  description = "Number of consecutive 1-minute periods CPU must stay above the critical threshold before alarming."
  type        = number
  default     = 5
}

###############################################################################
# Threshold configuration - ECS memory utilization
###############################################################################

variable "ecs_memory_warn_threshold_percent" {
  description = "ECS service memory utilization percent at which the warning alarm triggers."
  type        = number
  default     = 75
}

variable "ecs_memory_warn_evaluation_minutes" {
  description = "Number of consecutive 1-minute periods memory must stay above the warning threshold before alarming."
  type        = number
  default     = 10
}

variable "ecs_memory_crit_threshold_percent" {
  description = "ECS service memory utilization percent at which the critical alarm triggers."
  type        = number
  default     = 90
}

variable "ecs_memory_crit_evaluation_minutes" {
  description = "Number of consecutive 1-minute periods memory must stay above the critical threshold before alarming."
  type        = number
  default     = 5
}

###############################################################################
# Threshold configuration - ECS container restarts
###############################################################################

variable "ecs_container_restart_period_seconds" {
  description = "Window (seconds) over which container restarts are summed for both warning and critical alarms."
  type        = number
  default     = 600
}

variable "ecs_container_restart_warn_threshold" {
  description = "Number of container restarts within the window at which the warning alarm triggers."
  type        = number
  default     = 3
}

variable "ecs_container_restart_crit_threshold" {
  description = "Number of container restarts within the window at which the critical alarm triggers."
  type        = number
  default     = 5
}

###############################################################################
# Threshold configuration - ALB 5xx errors
#
# Emitted upstream as a raw count metric (HTTPCode_ELB_5XX_Count), not a rate,
# so thresholds here are counts per evaluation window rather than percentages.
# Tune these per ALB traffic volume to approximate the org's warn ~1% / crit
# ~5% error-rate guidance.
###############################################################################

variable "alb_5xx_period_seconds" {
  description = "Window (seconds) over which ALB 5xx responses are summed."
  type        = number
  default     = 300
}

variable "alb_5xx_evaluation_periods" {
  description = "Number of consecutive windows the 5xx count must breach the threshold before alarming."
  type        = number
  default     = 2
}

variable "alb_5xx_warn_threshold_count" {
  description = "Count of 5xx responses per window at which the warning alarm triggers."
  type        = number
  default     = 10
}

variable "alb_5xx_crit_threshold_count" {
  description = "Count of 5xx responses per window at which the critical alarm triggers."
  type        = number
  default     = 25
}

###############################################################################
# Threshold configuration - ALB latency (TargetResponseTime, p95)
###############################################################################

variable "alb_latency_period_seconds" {
  description = "Window (seconds) over which p95 target response time is evaluated."
  type        = number
  default     = 60
}

variable "alb_latency_evaluation_periods" {
  description = "Number of consecutive windows p95 latency must breach the threshold before alarming."
  type        = number
  default     = 5
}

variable "alb_latency_warn_threshold_seconds" {
  description = "p95 target response time (seconds) at which the warning alarm triggers."
  type        = number
  default     = 1
}

variable "alb_latency_crit_threshold_seconds" {
  description = "p95 target response time (seconds) at which the critical alarm triggers."
  type        = number
  default     = 3
}

###############################################################################
# Threshold configuration - EC2 CPU utilization (native AWS/EC2 metric,
# same on Linux and Windows)
###############################################################################

variable "ec2_cpu_warn_threshold_percent" {
  description = "EC2 CPU utilization percent at which the warning alarm triggers."
  type        = number
  default     = 70
}

variable "ec2_cpu_warn_evaluation_minutes" {
  description = "Number of consecutive 1-minute periods CPU must stay above the warning threshold before alarming."
  type        = number
  default     = 10
}

variable "ec2_cpu_crit_threshold_percent" {
  description = "EC2 CPU utilization percent at which the critical alarm triggers."
  type        = number
  default     = 85
}

variable "ec2_cpu_crit_evaluation_minutes" {
  description = "Number of consecutive 1-minute periods CPU must stay above the critical threshold before alarming."
  type        = number
  default     = 5
}

###############################################################################
# Threshold configuration - EC2 memory utilization (CWAgent; mem_used_percent
# on Linux, "Memory % Committed Bytes In Use" on Windows — both already
# expressed as a "used" percentage, no direction inversion needed)
###############################################################################

variable "ec2_memory_warn_threshold_percent" {
  description = "EC2 memory utilization percent at which the warning alarm triggers."
  type        = number
  default     = 75
}

variable "ec2_memory_warn_evaluation_minutes" {
  description = "Number of consecutive 1-minute periods memory must stay above the warning threshold before alarming."
  type        = number
  default     = 10
}

variable "ec2_memory_crit_threshold_percent" {
  description = "EC2 memory utilization percent at which the critical alarm triggers."
  type        = number
  default     = 90
}

variable "ec2_memory_crit_evaluation_minutes" {
  description = "Number of consecutive 1-minute periods memory must stay above the critical threshold before alarming."
  type        = number
  default     = 5
}

###############################################################################
# Threshold configuration - EC2 disk usage (CWAgent LogicalDisk, Windows
# only — see ec2_instances/README). "% Free Space" is inverted relative to
# a "used" percentage, so the module flips both the comparison operator and
# the threshold (100 - used_threshold) rather than exposing a separate
# free-space variable.
###############################################################################

variable "ec2_disk_warn_threshold_percent" {
  description = "EC2 disk usage percent (used) at which the warning alarm triggers."
  type        = number
  default     = 75
}

variable "ec2_disk_warn_evaluation_periods" {
  description = "Number of consecutive periods disk usage must stay above the warning threshold before alarming."
  type        = number
  default     = 5
}

variable "ec2_disk_crit_threshold_percent" {
  description = "EC2 disk usage percent (used) at which the critical alarm triggers."
  type        = number
  default     = 90
}

variable "ec2_disk_crit_evaluation_periods" {
  description = "Number of consecutive periods disk usage must stay above the critical threshold before alarming."
  type        = number
  default     = 3
}

variable "ec2_disk_period_seconds" {
  description = "Window (seconds) over which EC2 disk usage is evaluated."
  type        = number
  default     = 60
}

###############################################################################
# Threshold configuration - EC2 disk I/O wait (CWAgent PhysicalDisk
# "% Disk Time" on the "_Total" aggregate instance, Windows only — see
# ec2_instances/README). Already a percentage, used directly.
###############################################################################

variable "ec2_diskio_warn_threshold_percent" {
  description = "EC2 disk I/O wait/busy percent at which the warning alarm triggers."
  type        = number
  default     = 20
}

variable "ec2_diskio_crit_threshold_percent" {
  description = "EC2 disk I/O wait/busy percent at which the critical alarm triggers."
  type        = number
  default     = 40
}

variable "ec2_diskio_period_seconds" {
  description = "Window (seconds) over which EC2 disk I/O wait/busy percent is evaluated."
  type        = number
  default     = 60
}

variable "ec2_diskio_evaluation_periods" {
  description = "Number of consecutive periods disk I/O wait/busy percent must breach its threshold before alarming."
  type        = number
  default     = 5
}

###############################################################################
# Threshold configuration - EC2 network errors.
#
# Windows only for now (see ec2_instances.enable_network_errors). Summed as
# a raw error count, not a rate, like the ALB 5xx alarms — CWAgent's
# "Network Interface" Packets Received/Outbound Errors counters aren't
# naturally a percentage either. Assumes one active network interface per
# instance; an instance with multiple interfaces may need per-interface
# handling this module doesn't yet provide.
###############################################################################

variable "ec2_network_errors_period_seconds" {
  description = "Window (seconds) over which EC2 network interface errors are summed."
  type        = number
  default     = 300
}

variable "ec2_network_errors_evaluation_periods" {
  description = "Number of consecutive windows the network error count must breach the threshold before alarming."
  type        = number
  default     = 2
}

variable "ec2_network_errors_warn_threshold_count" {
  description = "Count of network interface errors (received + outbound) per window at which the warning alarm triggers."
  type        = number
  default     = 1
}

variable "ec2_network_errors_crit_threshold_count" {
  description = "Count of network interface errors (received + outbound) per window at which the critical alarm triggers."
  type        = number
  default     = 10
}

variable "ec2_network_adapter_name" {
  description = <<-EOT
    Windows perfmon "Network Interface" instance name CWAgent publishes
    network-error metrics under. Confirmed live on a t3a instance:
    "Amazon Elastic Network Adapter" (the standard ENA driver name used by
    virtually all current-generation instance types). Override if a target
    instance uses a different network adapter driver.
  EOT
  type        = string
  default     = "Amazon Elastic Network Adapter"
}

###############################################################################
# Threshold configuration - EC2 status checks
###############################################################################

variable "ec2_status_check_period_seconds" {
  description = "Window (seconds) over which the EC2 StatusCheckFailed metric is evaluated."
  type        = number
  default     = 60
}

variable "ec2_status_check_evaluation_periods" {
  description = "Number of consecutive windows StatusCheckFailed must be non-zero before alarming."
  type        = number
  default     = 2
}

###############################################################################
# Threshold configuration - Lambda error rate
###############################################################################

variable "lambda_error_rate_period_seconds" {
  description = "Window (seconds) over which Lambda invocations/errors are summed to compute error rate."
  type        = number
  default     = 300
}

variable "lambda_error_rate_evaluation_periods" {
  description = "Number of consecutive windows the error rate must breach the threshold before alarming."
  type        = number
  default     = 1
}

variable "lambda_error_rate_warn_percent" {
  description = "Lambda error rate percent (errors/invocations * 100) at which the warning alarm triggers."
  type        = number
  default     = 1
}

variable "lambda_error_rate_crit_percent" {
  description = "Lambda error rate percent (errors/invocations * 100) at which the critical alarm triggers."
  type        = number
  default     = 5
}

###############################################################################
# Threshold configuration - Lambda duration (p95)
###############################################################################

variable "lambda_duration_period_seconds" {
  description = "Window (seconds) over which p95 Lambda duration is evaluated."
  type        = number
  default     = 300
}

variable "lambda_duration_evaluation_periods" {
  description = "Number of consecutive windows p95 duration must breach the threshold before alarming."
  type        = number
  default     = 1
}

variable "lambda_duration_warn_percent_of_timeout" {
  description = "p95 duration as a percent of the function's configured timeout at which the warning alarm triggers."
  type        = number
  default     = 75
}

variable "lambda_duration_crit_percent_of_timeout" {
  description = "p95 duration as a percent of the function's configured timeout at which the critical alarm triggers."
  type        = number
  default     = 90
}

###############################################################################
# Threshold configuration - Lambda throttles
###############################################################################

variable "lambda_throttle_period_seconds" {
  description = "Window (seconds) over which Lambda throttles are summed."
  type        = number
  default     = 300
}

variable "lambda_throttle_evaluation_periods" {
  description = "Number of consecutive windows throttle count must breach the threshold before alarming."
  type        = number
  default     = 1
}

variable "lambda_throttle_threshold" {
  description = "Count of throttled invocations per window at which the alarm triggers."
  type        = number
  default     = 1
}

###############################################################################
# Threshold configuration - Lambda concurrent executions
###############################################################################

variable "lambda_concurrency_period_seconds" {
  description = "Window (seconds) over which max concurrent executions is evaluated."
  type        = number
  default     = 60
}

variable "lambda_concurrency_evaluation_periods" {
  description = "Number of consecutive windows concurrency must breach the threshold before alarming."
  type        = number
  default     = 5
}

variable "lambda_concurrency_warn_percent" {
  description = "Concurrent executions as a percent of the function's concurrency limit at which the warning alarm triggers."
  type        = number
  default     = 80
}

variable "lambda_concurrency_crit_percent" {
  description = "Concurrent executions as a percent of the function's concurrency limit at which the critical alarm triggers."
  type        = number
  default     = 95
}
