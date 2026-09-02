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

  ec2_memory_instances = { for k, v in var.ec2_instances : k => v if v.enable_memory }

  # Disk I/O wait and network errors are supported on both OSes, but each
  # got there differently: Windows disk I/O wait uses PhysicalDisk's
  # well-known "_Total" aggregate instance (msi-terraform-cloudwatch-agent
  # >= v0.2.3); Linux uses cpu_usage_iowait, a system-wide percentage with
  # no per-device dimension at all (>= v0.2.8) - both sidestep the same
  # "CloudWatch alarms can't use SEARCH()" problem (confirmed live:
  # "ValidationError: SEARCH is not supported on Metric Alarms") without
  # needing a per-instance opt-in value. Network errors are inherently
  # per-interface on both OSes, so both use a global interface-name
  # variable (ec2_network_adapter_name / ec2_linux_network_interface_name)
  # rather than a per-instance field, on the assumption of one active
  # interface per instance.
  ec2_diskio_instances         = { for k, v in var.ec2_instances : k => v if v.enable_diskio }
  ec2_network_errors_instances = { for k, v in var.ec2_instances : k => v if v.enable_network_errors }

  # One entry per (instance, disk resource) pair, for disk-usage alarms.
  # Windows drive letters contain ":" which isn't valid in a map
  # key/alarm-name segment, so it's stripped there. Linux disk_used_percent
  # carries an fstype dimension whose value isn't knowable from Terraform
  # (same SEARCH() problem as above, but with no aggregate/system-wide
  # equivalent available for per-mount disk usage) - callers must supply it
  # explicitly per path via linux_disk_paths, checked live beforehand.
  ec2_disk_pairs = merge(concat(
    [
      for k, v in var.ec2_instances : v.os_type != "windows" ? {} : {
        for dr in v.disk_resources : "${k}-${replace(dr, ":", "")}" => {
          instance_key = k
          instance_id  = v.instance_id
          os_type      = v.os_type
          disk         = dr
          fstype       = null
        }
      }
    ],
    [
      for k, v in var.ec2_instances : v.os_type != "linux" ? {} : {
        for dp in v.linux_disk_paths : "${k}-${dp.path == "/" ? "root" : replace(trimprefix(dp.path, "/"), "/", "-")}" => {
          instance_key = k
          instance_id  = v.instance_id
          os_type      = v.os_type
          disk         = dp.path
          fstype       = dp.fstype
        }
      }
    ]
  )...)

  # One entry per (ALB, target group) pair, for Healthy/Unhealthy Target
  # Count alarms - both metrics are TargetGroup-dimensioned, not ALB-level
  # like the 5xx/latency alarms above, so this needs the LoadBalancer
  # dimension carried alongside each target group.
  alb_target_group_pairs = merge([
    for alb_key, alb in var.albs : {
      for tg_key, tg in alb.target_groups : "${alb_key}-${tg_key}" => {
        alb_key  = alb_key
        alb_name = alb.name
        tg_name  = tg.name
      }
    }
  ]...)

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
# ALB target group Healthy/Unhealthy Target Count - both metrics require
# LoadBalancer + TargetGroup dimensions together (TargetGroup alone is
# rejected by CloudWatch), unlike the ALB-level 5xx/latency alarms above.
###############################################################################

module "alb_unhealthy_targets_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.alb_target_group_pairs

  alarm_name          = "UnhealthyTargets-Warn-${each.key}"
  alarm_description   = "Triggers when target group ${each.key} has at least ${var.alb_unhealthy_targets_warn_threshold_count} unhealthy target(s)"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  period              = var.alb_target_group_health_period_seconds
  evaluation_periods  = var.alb_target_group_health_evaluation_periods
  threshold           = var.alb_unhealthy_targets_warn_threshold_count
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = {
    LoadBalancer = each.value.alb_name
    TargetGroup  = each.value.tg_name
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "alb_healthy_targets_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.alb_target_group_pairs

  alarm_name          = "ZeroHealthyTargets-Crit-${each.key}"
  alarm_description   = "Triggers when target group ${each.key} has ${var.alb_healthy_targets_crit_threshold_count} or fewer healthy targets"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = var.alb_target_group_health_period_seconds
  evaluation_periods  = var.alb_target_group_health_evaluation_periods
  threshold           = var.alb_healthy_targets_crit_threshold_count
  comparison_operator = "LessThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = each.value.alb_name
    TargetGroup  = each.value.tg_name
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# EC2 CPU utilization - native AWS/EC2 metric, identical on Linux and
# Windows, no CloudWatch Agent required.
###############################################################################

module "ec2_cpu_utilization_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.ec2_instances

  alarm_name          = "HighCPUUtilization-Warn-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} exceeds ${var.ec2_cpu_warn_threshold_percent}% CPU for ${var.ec2_cpu_warn_evaluation_minutes} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  evaluation_periods  = var.ec2_cpu_warn_evaluation_minutes
  period              = 60
  statistic           = "Average"
  threshold           = var.ec2_cpu_warn_threshold_percent
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = each.value.instance_id
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "ec2_cpu_utilization_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = var.ec2_instances

  alarm_name          = "HighCPUUtilization-Crit-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} exceeds ${var.ec2_cpu_crit_threshold_percent}% CPU for ${var.ec2_cpu_crit_evaluation_minutes} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  evaluation_periods  = var.ec2_cpu_crit_evaluation_minutes
  period              = 60
  statistic           = "Average"
  threshold           = var.ec2_cpu_crit_threshold_percent
  treat_missing_data  = "missing"

  dimensions = {
    InstanceId = each.value.instance_id
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# EC2 memory utilization - CWAgent. mem_used_percent (Linux) and "Memory %
# Committed Bytes In Use" (Windows) are both already "used" percentages, so
# no direction inversion is needed between OSes.
###############################################################################

module "ec2_memory_utilization_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_memory_instances

  alarm_name          = "HighMemoryUtilization-Warn-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} exceeds ${var.ec2_memory_warn_threshold_percent}% memory for ${var.ec2_memory_warn_evaluation_minutes} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = each.value.os_type == "windows" ? "Memory % Committed Bytes In Use" : "mem_used_percent"
  namespace           = "CWAgent"
  evaluation_periods  = var.ec2_memory_warn_evaluation_minutes
  period              = 60
  statistic           = "Average"
  threshold           = var.ec2_memory_warn_threshold_percent
  treat_missing_data  = "missing"

  dimensions = each.value.os_type == "windows" ? {
    InstanceId = each.value.instance_id
    objectname = "Memory"
    } : {
    InstanceId = each.value.instance_id
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "ec2_memory_utilization_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_memory_instances

  alarm_name          = "HighMemoryUtilization-Crit-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} exceeds ${var.ec2_memory_crit_threshold_percent}% memory for ${var.ec2_memory_crit_evaluation_minutes} minutes"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = each.value.os_type == "windows" ? "Memory % Committed Bytes In Use" : "mem_used_percent"
  namespace           = "CWAgent"
  evaluation_periods  = var.ec2_memory_crit_evaluation_minutes
  period              = 60
  statistic           = "Average"
  threshold           = var.ec2_memory_crit_threshold_percent
  treat_missing_data  = "missing"

  dimensions = each.value.os_type == "windows" ? {
    InstanceId = each.value.instance_id
    objectname = "Memory"
    } : {
    InstanceId = each.value.instance_id
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# EC2 disk usage - CWAgent LogicalDisk "% Free Space", one alarm per
# (instance, disk_resources entry). Windows only — see ec2_disk_pairs.
# "% Free Space" is inverted relative to a "used" percentage, so the
# comparison operator and threshold (100 - used_threshold) are flipped.
###############################################################################

module "ec2_disk_usage_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_disk_pairs

  alarm_name          = "HighDiskUsage-Warn-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} disk ${each.value.disk} exceeds ${var.ec2_disk_warn_threshold_percent}% used"
  comparison_operator = each.value.os_type == "windows" ? "LessThanOrEqualToThreshold" : "GreaterThanOrEqualToThreshold"
  metric_name         = each.value.os_type == "windows" ? "LogicalDisk % Free Space" : "disk_used_percent"
  namespace           = "CWAgent"
  period              = var.ec2_disk_period_seconds
  statistic           = "Average"
  evaluation_periods  = var.ec2_disk_warn_evaluation_periods
  threshold           = each.value.os_type == "windows" ? 100 - var.ec2_disk_warn_threshold_percent : var.ec2_disk_warn_threshold_percent
  treat_missing_data  = "missing"

  dimensions = each.value.os_type == "windows" ? {
    InstanceId = each.value.instance_id
    objectname = "LogicalDisk"
    instance   = each.value.disk
    } : {
    InstanceId = each.value.instance_id
    path       = each.value.disk
    fstype     = each.value.fstype
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "ec2_disk_usage_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_disk_pairs

  alarm_name          = "HighDiskUsage-Crit-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} disk ${each.value.disk} exceeds ${var.ec2_disk_crit_threshold_percent}% used"
  comparison_operator = each.value.os_type == "windows" ? "LessThanOrEqualToThreshold" : "GreaterThanOrEqualToThreshold"
  metric_name         = each.value.os_type == "windows" ? "LogicalDisk % Free Space" : "disk_used_percent"
  namespace           = "CWAgent"
  period              = var.ec2_disk_period_seconds
  statistic           = "Average"
  evaluation_periods  = var.ec2_disk_crit_evaluation_periods
  threshold           = each.value.os_type == "windows" ? 100 - var.ec2_disk_crit_threshold_percent : var.ec2_disk_crit_threshold_percent
  treat_missing_data  = "missing"

  dimensions = each.value.os_type == "windows" ? {
    InstanceId = each.value.instance_id
    objectname = "LogicalDisk"
    instance   = each.value.disk
    } : {
    InstanceId = each.value.instance_id
    path       = each.value.disk
    fstype     = each.value.fstype
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# EC2 disk I/O wait - Windows: CWAgent PhysicalDisk "% Disk Time" on the
# "_Total" aggregate instance (msi-terraform-cloudwatch-agent >= v0.2.3).
# Linux: cpu_usage_iowait, a system-wide percentage with no per-device
# dimension (>= v0.2.8) - see msi-terraform-cloudwatch-agent's README for
# why this is used instead of diskio_io_time (a raw, unpredictable-device
# counter, not a percentage).
###############################################################################

module "ec2_diskio_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_diskio_instances

  alarm_name          = "HighDiskIOWait-Warn-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} disk I/O busy time exceeds ${var.ec2_diskio_warn_threshold_percent}%"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = each.value.os_type == "windows" ? "% Disk Time" : "cpu_usage_iowait"
  namespace           = "CWAgent"
  period              = var.ec2_diskio_period_seconds
  statistic           = "Average"
  evaluation_periods  = var.ec2_diskio_evaluation_periods
  threshold           = var.ec2_diskio_warn_threshold_percent
  treat_missing_data  = "missing"

  dimensions = each.value.os_type == "windows" ? {
    InstanceId = each.value.instance_id
    objectname = "PhysicalDisk"
    instance   = "_Total"
    } : {
    InstanceId = each.value.instance_id
    # msi-terraform-cloudwatch-agent's Linux config sets totalcpu = true,
    # which CWAgent publishes cpu_usage_iowait under a "cpu" = "cpu-total"
    # dimension (confirmed live via `aws cloudwatch list-metrics`) -
    # CloudWatch alarms require an exact dimension-set match, so omitting
    # this left the alarm in INSUFFICIENT_DATA even once the metric itself
    # existed.
    cpu = "cpu-total"
  }

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "ec2_diskio_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_diskio_instances

  alarm_name          = "HighDiskIOWait-Crit-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} disk I/O busy time exceeds ${var.ec2_diskio_crit_threshold_percent}%"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  metric_name         = each.value.os_type == "windows" ? "% Disk Time" : "cpu_usage_iowait"
  namespace           = "CWAgent"
  period              = var.ec2_diskio_period_seconds
  statistic           = "Average"
  evaluation_periods  = var.ec2_diskio_evaluation_periods
  threshold           = var.ec2_diskio_crit_threshold_percent
  treat_missing_data  = "missing"

  dimensions = each.value.os_type == "windows" ? {
    InstanceId = each.value.instance_id
    objectname = "PhysicalDisk"
    instance   = "_Total"
    } : {
    InstanceId = each.value.instance_id
    # See ec2_diskio_warn above - totalcpu = true publishes cpu_usage_iowait
    # under cpu = "cpu-total", not just InstanceId alone.
    cpu = "cpu-total"
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# EC2 network errors - works on both OSes as of msi-terraform-cloudwatch-agent
# >= v0.2.7 (Linux net plugin). Summed as a raw count like the ALB 5xx
# alarms, not a rate. Assumes one active network interface per instance -
# see ec2_network_adapter_name / ec2_linux_network_interface_name.
###############################################################################

module "ec2_network_errors_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_network_errors_instances

  alarm_name          = "NetworkInterfaceErrors-Warn-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} network interface errors reach ${var.ec2_network_errors_warn_threshold_count} in a window"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.ec2_network_errors_evaluation_periods
  threshold           = var.ec2_network_errors_warn_threshold_count
  treat_missing_data  = "notBreaching"

  metric_query = [
    {
      id          = "total_errors"
      expression  = "received_errors + outbound_errors"
      label       = "NetworkInterfaceErrors"
      return_data = "true"
    },
    {
      id = "received_errors"
      metric = [{
        metric_name = each.value.os_type == "windows" ? "Network Interface Packets Received Errors" : "net_err_in"
        namespace   = "CWAgent"
        period      = var.ec2_network_errors_period_seconds
        stat        = "Sum"
        dimensions = each.value.os_type == "windows" ? {
          InstanceId = each.value.instance_id
          objectname = "Network Interface"
          instance   = var.ec2_network_adapter_name
          } : {
          InstanceId = each.value.instance_id
          interface  = var.ec2_linux_network_interface_name
        }
      }]
    },
    {
      id = "outbound_errors"
      metric = [{
        metric_name = each.value.os_type == "windows" ? "Network Interface Packets Outbound Errors" : "net_err_out"
        namespace   = "CWAgent"
        period      = var.ec2_network_errors_period_seconds
        stat        = "Sum"
        dimensions = each.value.os_type == "windows" ? {
          InstanceId = each.value.instance_id
          objectname = "Network Interface"
          instance   = var.ec2_network_adapter_name
          } : {
          InstanceId = each.value.instance_id
          interface  = var.ec2_linux_network_interface_name
        }
      }]
    },
  ]

  alarm_actions = [var.sns_topic_arns.warning_alarm_arn]
  ok_actions    = [var.sns_topic_arns.warning_ok_arn]

  tags = local.tags_warn
}

module "ec2_network_errors_crit" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_network_errors_instances

  alarm_name          = "NetworkInterfaceErrors-Crit-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} network interface errors reach ${var.ec2_network_errors_crit_threshold_count} in a window"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.ec2_network_errors_evaluation_periods
  threshold           = var.ec2_network_errors_crit_threshold_count
  treat_missing_data  = "notBreaching"

  metric_query = [
    {
      id          = "total_errors"
      expression  = "received_errors + outbound_errors"
      label       = "NetworkInterfaceErrors"
      return_data = "true"
    },
    {
      id = "received_errors"
      metric = [{
        metric_name = each.value.os_type == "windows" ? "Network Interface Packets Received Errors" : "net_err_in"
        namespace   = "CWAgent"
        period      = var.ec2_network_errors_period_seconds
        stat        = "Sum"
        dimensions = each.value.os_type == "windows" ? {
          InstanceId = each.value.instance_id
          objectname = "Network Interface"
          instance   = var.ec2_network_adapter_name
          } : {
          InstanceId = each.value.instance_id
          interface  = var.ec2_linux_network_interface_name
        }
      }]
    },
    {
      id = "outbound_errors"
      metric = [{
        metric_name = each.value.os_type == "windows" ? "Network Interface Packets Outbound Errors" : "net_err_out"
        namespace   = "CWAgent"
        period      = var.ec2_network_errors_period_seconds
        stat        = "Sum"
        dimensions = each.value.os_type == "windows" ? {
          InstanceId = each.value.instance_id
          objectname = "Network Interface"
          instance   = var.ec2_network_adapter_name
          } : {
          InstanceId = each.value.instance_id
          interface  = var.ec2_linux_network_interface_name
        }
      }]
    },
  ]

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
  for_each = var.ec2_instances

  alarm_name          = "EC2StatusCheckFailed-${each.key}"
  alarm_description   = "Triggers when instance ${each.value.instance_id} fails its system or instance status check"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = var.ec2_status_check_period_seconds
  evaluation_periods  = var.ec2_status_check_evaluation_periods
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "breaching"

  dimensions = {
    InstanceId = each.value.instance_id
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
      id = "invocations"
      metric = [{
        metric_name = "Invocations"
        namespace   = "AWS/Lambda"
        period      = var.lambda_error_rate_period_seconds
        stat        = "Sum"
        dimensions = {
          FunctionName = each.value.function_name
        }
      }]
    },
    {
      id = "errors"
      metric = [{
        metric_name = "Errors"
        namespace   = "AWS/Lambda"
        period      = var.lambda_error_rate_period_seconds
        stat        = "Sum"
        dimensions = {
          FunctionName = each.value.function_name
        }
      }]
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
      id = "invocations"
      metric = [{
        metric_name = "Invocations"
        namespace   = "AWS/Lambda"
        period      = var.lambda_error_rate_period_seconds
        stat        = "Sum"
        dimensions = {
          FunctionName = each.value.function_name
        }
      }]
    },
    {
      id = "errors"
      metric = [{
        metric_name = "Errors"
        namespace   = "AWS/Lambda"
        period      = var.lambda_error_rate_period_seconds
        stat        = "Sum"
        dimensions = {
          FunctionName = each.value.function_name
        }
      }]
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
