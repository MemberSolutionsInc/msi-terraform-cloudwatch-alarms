locals {
  ecs_services = flatten([
    for cluster_key, cluster in var.ecs_clusters :
    cluster.create ? [
      for service_name in cluster.services : {
        key          = "${cluster_key}-${service_name}"
        cluster_name = cluster.cluster_name
        service_name = service_name
      }
    ] : []
  ])
  ecs_services_map = { for svc in local.ecs_services : svc.key => svc }

  # Per-alarm severity override: applied on top of the caller-supplied
  # mandatory tags so the crit alarm always says severity=critical and the
  # warn alarm always says severity=warning, regardless of what the caller
  # passed for that one key.
  tags_warn = merge(var.tags, { severity = "warning" })
  tags_crit = merge(var.tags, { severity = "critical" })
}

###############################################################################
# ECS CPU utilization
###############################################################################

module "ecs_cpu_utilization_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ecs_services_map

  alarm_name          = "HighCPUUtilization-Warn-${each.value.service_name}"
  alarm_description   = "Triggers if ECS service ${each.value.service_name} in cluster ${each.value.cluster_name} exceeds ${var.ecs_cpu_warn_threshold_percent}% CPU for ${var.ecs_cpu_warn_evaluation_minutes} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  evaluation_periods  = var.ecs_cpu_warn_evaluation_minutes
  period              = 60
  statistic           = "Average"
  threshold           = var.ecs_cpu_warn_threshold_percent
  treat_missing_data  = "missing"

  dimensions = {
    ClusterName = each.value.cluster_name
    ServiceName = each.value.service_name
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "ecs_cpu_utilization_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ecs_services_map

  alarm_name          = "HighCPUUtilization-Crit-${each.value.service_name}"
  alarm_description   = "Triggers if ECS service ${each.value.service_name} in cluster ${each.value.cluster_name} exceeds ${var.ecs_cpu_crit_threshold_percent}% CPU for ${var.ecs_cpu_crit_evaluation_minutes} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  evaluation_periods  = var.ecs_cpu_crit_evaluation_minutes
  period              = 60
  statistic           = "Average"
  threshold           = var.ecs_cpu_crit_threshold_percent
  treat_missing_data  = "missing"

  dimensions = {
    ClusterName = each.value.cluster_name
    ServiceName = each.value.service_name
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# ECS memory utilization
###############################################################################

module "ecs_memory_utilization_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ecs_services_map

  alarm_name          = "HighMemoryUtilization-Warn-${each.value.service_name}"
  alarm_description   = "Triggers if ECS service ${each.value.service_name} in cluster ${each.value.cluster_name} exceeds ${var.ecs_memory_warn_threshold_percent}% memory for ${var.ecs_memory_warn_evaluation_minutes} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  evaluation_periods  = var.ecs_memory_warn_evaluation_minutes
  period              = 60
  statistic           = "Average"
  threshold           = var.ecs_memory_warn_threshold_percent
  treat_missing_data  = "missing"

  dimensions = {
    ClusterName = each.value.cluster_name
    ServiceName = each.value.service_name
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "ecs_memory_utilization_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ecs_services_map

  alarm_name          = "HighMemoryUtilization-Crit-${each.value.service_name}"
  alarm_description   = "Triggers if ECS service ${each.value.service_name} in cluster ${each.value.cluster_name} exceeds ${var.ecs_memory_crit_threshold_percent}% memory for ${var.ecs_memory_crit_evaluation_minutes} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "MemoryUtilization"
  namespace           = "AWS/ECS"
  evaluation_periods  = var.ecs_memory_crit_evaluation_minutes
  period              = 60
  statistic           = "Average"
  threshold           = var.ecs_memory_crit_threshold_percent
  treat_missing_data  = "missing"

  dimensions = {
    ClusterName = each.value.cluster_name
    ServiceName = each.value.service_name
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# ECS container restarts - frequent restarts may indicate crashes or
# misconfigurations.
###############################################################################

module "ecs_container_restart_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ecs_services_map

  alarm_name          = "HighContainerRestarts-Warn-${each.value.service_name}"
  alarm_description   = "Triggers when container restarts for ${each.value.service_name} in cluster ${each.value.cluster_name} reach ${var.ecs_container_restart_warn_threshold} within ${var.ecs_container_restart_period_seconds / 60} minutes"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RestartCount"
  statistic           = "Sum"
  period              = var.ecs_container_restart_period_seconds
  evaluation_periods  = 1
  threshold           = var.ecs_container_restart_warn_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    ClusterName = each.value.cluster_name
    ServiceName = each.value.service_name
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "ecs_container_restart_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ecs_services_map

  alarm_name          = "HighContainerRestarts-Crit-${each.value.service_name}"
  alarm_description   = "Triggers when container restarts for ${each.value.service_name} in cluster ${each.value.cluster_name} reach ${var.ecs_container_restart_crit_threshold} within ${var.ecs_container_restart_period_seconds / 60} minutes"
  namespace           = "ECS/ContainerInsights"
  metric_name         = "RestartCount"
  statistic           = "Sum"
  period              = var.ecs_container_restart_period_seconds
  evaluation_periods  = 1
  threshold           = var.ecs_container_restart_crit_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    ClusterName = each.value.cluster_name
    ServiceName = each.value.service_name
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# ALB 5xx errors - emitted as a raw count metric upstream, so thresholds are
# counts per window (see variables.tf) rather than a rate.
###############################################################################

module "alb_5xx_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.albs

  alarm_name          = "High5XXErrors-Warn-${each.key}"
  alarm_description   = "Triggers when ALB ${each.key} returns at least ${var.alb_5xx_warn_threshold_count} 5XX errors in ${var.alb_5xx_period_seconds / 60} minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = var.alb_5xx_period_seconds
  evaluation_periods  = var.alb_5xx_evaluation_periods
  threshold           = var.alb_5xx_warn_threshold_count
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = each.value.name
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "alb_5xx_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.albs

  alarm_name          = "High5XXErrors-Crit-${each.key}"
  alarm_description   = "Triggers when ALB ${each.key} returns at least ${var.alb_5xx_crit_threshold_count} 5XX errors in ${var.alb_5xx_period_seconds / 60} minutes"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_ELB_5XX_Count"
  statistic           = "Sum"
  period              = var.alb_5xx_period_seconds
  evaluation_periods  = var.alb_5xx_evaluation_periods
  threshold           = var.alb_5xx_crit_threshold_count
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = each.value.name
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# ALB latency (TargetResponseTime, p95)
###############################################################################

module "alb_latency_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.albs

  alarm_name          = "HighLatency-Warn-${each.key}"
  alarm_description   = "Triggers when ALB ${each.key} p95 target response time exceeds ${var.alb_latency_warn_threshold_seconds}s"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = var.alb_latency_period_seconds
  evaluation_periods  = var.alb_latency_evaluation_periods
  threshold           = var.alb_latency_warn_threshold_seconds
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    LoadBalancer = each.value.name
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "alb_latency_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.albs

  alarm_name          = "HighLatency-Crit-${each.key}"
  alarm_description   = "Triggers when ALB ${each.key} p95 target response time exceeds ${var.alb_latency_crit_threshold_seconds}s"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  extended_statistic  = "p95"
  period              = var.alb_latency_period_seconds
  evaluation_periods  = var.alb_latency_evaluation_periods
  threshold           = var.alb_latency_crit_threshold_seconds
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "missing"

  dimensions = {
    LoadBalancer = each.value.name
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# EC2 status checks - StatusCheckFailed already aggregates the underlying
# StatusCheckFailed_Instance and StatusCheckFailed_System checks, so a single
# alarm module per instance covers both failure modes.
###############################################################################

module "ec2_status_check_failed" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = toset(var.ec2_instance_ids)

  alarm_name          = "EC2StatusCheckFailed-${each.value}"
  alarm_description   = "Triggers when instance ${each.value} fails its system or instance status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = var.ec2_status_check_period_seconds
  evaluation_periods  = var.ec2_status_check_evaluation_periods
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = each.value
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = var.tags
}

###############################################################################
# Lambda error rate - errors/invocations expressed as a percentage via a
# metric-math expression.
###############################################################################

module "lambda_error_rate_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.lambda_functions

  alarm_name          = "HighErrorRate-Warn-${each.value.function_name}"
  alarm_description   = "Triggers when ${each.value.function_name} error rate reaches ${var.lambda_error_rate_warn_percent}%"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.lambda_error_rate_evaluation_periods
  threshold           = var.lambda_error_rate_warn_percent
  treat_missing_data  = "notBreaching"

  metric_query = [
    {
      id          = "error_rate"
      expression  = "(errors / invocations) * 100"
      label       = "ErrorRatePercent"
      return_data = "true"
    },
    {
      id          = "invocations"
      metric_name = "Invocations"
      namespace   = "AWS/Lambda"
      period      = var.lambda_error_rate_period_seconds
      stat        = "Sum"
      dimensions = {
        FunctionName = each.value.function_name
      }
    },
    {
      id          = "errors"
      metric_name = "Errors"
      namespace   = "AWS/Lambda"
      period      = var.lambda_error_rate_period_seconds
      stat        = "Sum"
      dimensions = {
        FunctionName = each.value.function_name
      }
    },
  ]

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "lambda_error_rate_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.lambda_functions

  alarm_name          = "HighErrorRate-Crit-${each.value.function_name}"
  alarm_description   = "Triggers when ${each.value.function_name} error rate reaches ${var.lambda_error_rate_crit_percent}%"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.lambda_error_rate_evaluation_periods
  threshold           = var.lambda_error_rate_crit_percent
  treat_missing_data  = "notBreaching"

  metric_query = [
    {
      id          = "error_rate"
      expression  = "(errors / invocations) * 100"
      label       = "ErrorRatePercent"
      return_data = "true"
    },
    {
      id          = "invocations"
      metric_name = "Invocations"
      namespace   = "AWS/Lambda"
      period      = var.lambda_error_rate_period_seconds
      stat        = "Sum"
      dimensions = {
        FunctionName = each.value.function_name
      }
    },
    {
      id          = "errors"
      metric_name = "Errors"
      namespace   = "AWS/Lambda"
      period      = var.lambda_error_rate_period_seconds
      stat        = "Sum"
      dimensions = {
        FunctionName = each.value.function_name
      }
    },
  ]

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# Lambda duration (p95, as a percent of the function's configured timeout)
###############################################################################

module "lambda_duration_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.lambda_functions

  alarm_name          = "HighDuration-Warn-${each.value.function_name}"
  alarm_description   = "Triggers when ${each.value.function_name} p95 duration reaches ${var.lambda_duration_warn_percent_of_timeout}% of its ${each.value.timeout_seconds}s timeout"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  extended_statistic  = "p95"
  period              = var.lambda_duration_period_seconds
  evaluation_periods  = var.lambda_duration_evaluation_periods
  threshold           = each.value.timeout_seconds * 1000 * var.lambda_duration_warn_percent_of_timeout / 100
  treat_missing_data  = "missing"

  dimensions = {
    FunctionName = each.value.function_name
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "lambda_duration_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.lambda_functions

  alarm_name          = "HighDuration-Crit-${each.value.function_name}"
  alarm_description   = "Triggers when ${each.value.function_name} p95 duration reaches ${var.lambda_duration_crit_percent_of_timeout}% of its ${each.value.timeout_seconds}s timeout"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  extended_statistic  = "p95"
  period              = var.lambda_duration_period_seconds
  evaluation_periods  = var.lambda_duration_evaluation_periods
  threshold           = each.value.timeout_seconds * 1000 * var.lambda_duration_crit_percent_of_timeout / 100
  treat_missing_data  = "missing"

  dimensions = {
    FunctionName = each.value.function_name
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# Lambda throttles - single-tier alarm
###############################################################################

module "lambda_throttles" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.lambda_functions

  alarm_name          = "Throttles-${each.value.function_name}"
  alarm_description   = "Triggers when ${each.value.function_name} is throttled at least ${var.lambda_throttle_threshold} time(s) in ${var.lambda_throttle_period_seconds / 60} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  statistic           = "Sum"
  period              = var.lambda_throttle_period_seconds
  evaluation_periods  = var.lambda_throttle_evaluation_periods
  threshold           = var.lambda_throttle_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value.function_name
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = var.tags
}

###############################################################################
# Lambda concurrent executions (percent of configured concurrency limit)
###############################################################################

module "lambda_concurrency_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.lambda_functions

  alarm_name          = "HighConcurrency-Warn-${each.value.function_name}"
  alarm_description   = "Triggers when ${each.value.function_name} concurrent executions reach ${var.lambda_concurrency_warn_percent}% of its limit of ${each.value.concurrency_limit}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "ConcurrentExecutions"
  namespace           = "AWS/Lambda"
  statistic           = "Maximum"
  period              = var.lambda_concurrency_period_seconds
  evaluation_periods  = var.lambda_concurrency_evaluation_periods
  threshold           = each.value.concurrency_limit * var.lambda_concurrency_warn_percent / 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value.function_name
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "lambda_concurrency_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.lambda_functions

  alarm_name          = "HighConcurrency-Crit-${each.value.function_name}"
  alarm_description   = "Triggers when ${each.value.function_name} concurrent executions reach ${var.lambda_concurrency_crit_percent}% of its limit of ${each.value.concurrency_limit}"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "ConcurrentExecutions"
  namespace           = "AWS/Lambda"
  statistic           = "Maximum"
  period              = var.lambda_concurrency_period_seconds
  evaluation_periods  = var.lambda_concurrency_evaluation_periods
  threshold           = each.value.concurrency_limit * var.lambda_concurrency_crit_percent / 100
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value.function_name
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}
