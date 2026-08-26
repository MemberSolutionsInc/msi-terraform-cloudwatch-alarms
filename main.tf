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

  ec2_memory_instances         = { for k, v in var.ec2_instances : k => v if v.enable_memory }
  ec2_diskio_instances         = { for k, v in var.ec2_instances : k => v if v.enable_diskio }
  ec2_network_errors_instances = { for k, v in var.ec2_instances : k => v if v.enable_network_errors && v.os_type == "windows" }

  # One entry per (instance, disk_resources entry) pair, for disk-usage
  # alarms. Windows drive letters contain ":" which isn't valid in a map
  # key/alarm-name segment, so it's stripped there.
  ec2_disk_pairs = merge([
    for k, v in var.ec2_instances : {
      for dr in v.disk_resources : "${k}-${replace(dr, ":", "")}" => {
        instance_id = v.instance_id
        os_type     = v.os_type
        disk        = dr
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

  dimensions = {
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

  dimensions = {
    InstanceId = each.value.instance_id
  }

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# EC2 disk usage - CWAgent, one alarm per (instance, disk_resources entry).
#
# Windows LogicalDisk "% Free Space" is inverted relative to Linux
# disk_used_percent (free, not used), so the comparison operator and
# threshold (100 - used_threshold) are flipped for Windows. Windows
# dimensions are fully known ahead of time (InstanceId + the drive letter we
# configured). Linux disk_used_percent also carries an unpredictable
# "fstype" dimension even with drop_device=true on the agent side, so the
# Linux alarm uses a SEARCH expression matching on {InstanceId, path} only,
# rather than a fixed dimension set that might not match.
###############################################################################

module "ec2_disk_usage_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_disk_pairs

  alarm_name          = "HighDiskUsage-Warn-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} disk ${each.value.disk} exceeds ${var.ec2_disk_warn_threshold_percent}% used"
  comparison_operator = each.value.os_type == "windows" ? "LessThanOrEqualToThreshold" : "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.ec2_disk_warn_evaluation_periods
  threshold           = each.value.os_type == "windows" ? (100 - var.ec2_disk_warn_threshold_percent) : var.ec2_disk_warn_threshold_percent
  treat_missing_data  = "missing"

  dimensions = each.value.os_type == "windows" ? {
    InstanceId = each.value.instance_id
    instance   = each.value.disk
  } : null

  metric_name = each.value.os_type == "windows" ? "LogicalDisk % Free Space" : null
  namespace   = each.value.os_type == "windows" ? "CWAgent" : null
  period      = each.value.os_type == "windows" ? var.ec2_disk_period_seconds : null
  statistic   = each.value.os_type == "windows" ? "Average" : null

  metric_query = each.value.os_type == "windows" ? [] : [
    {
      id          = "disk_used"
      expression  = "SEARCH('{CWAgent,InstanceId,path} MetricName=\"disk_used_percent\" InstanceId=\"${each.value.instance_id}\" path=\"${each.value.disk}\"', 'Average', ${var.ec2_disk_period_seconds})"
      label       = "DiskUsedPercent-${each.value.disk}"
      return_data = "true"
    },
  ]

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
  evaluation_periods  = var.ec2_disk_crit_evaluation_periods
  threshold           = each.value.os_type == "windows" ? (100 - var.ec2_disk_crit_threshold_percent) : var.ec2_disk_crit_threshold_percent
  treat_missing_data  = "missing"

  dimensions = each.value.os_type == "windows" ? {
    InstanceId = each.value.instance_id
    instance   = each.value.disk
  } : null

  metric_name = each.value.os_type == "windows" ? "LogicalDisk % Free Space" : null
  namespace   = each.value.os_type == "windows" ? "CWAgent" : null
  period      = each.value.os_type == "windows" ? var.ec2_disk_period_seconds : null
  statistic   = each.value.os_type == "windows" ? "Average" : null

  metric_query = each.value.os_type == "windows" ? [] : [
    {
      id          = "disk_used"
      expression  = "SEARCH('{CWAgent,InstanceId,path} MetricName=\"disk_used_percent\" InstanceId=\"${each.value.instance_id}\" path=\"${each.value.disk}\"', 'Average', ${var.ec2_disk_period_seconds})"
      label       = "DiskUsedPercent-${each.value.disk}"
      return_data = "true"
    },
  ]

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# EC2 disk I/O wait - one alarm per instance (not per disk_resources entry):
# both Windows PhysicalDisk "instance" values (physical-disk index, not the
# drive letter) and Linux diskio's "name" (block device name) are unknowable
# from Terraform ahead of time, so both use a SEARCH expression matching on
# InstanceId only, reduced with MAX across whichever devices/disks it finds
# — i.e. alarms on the single busiest disk on the instance.
#
# Windows PhysicalDisk "% Disk Time" is already a percentage. Linux
# diskio_io_time is a cumulative millisecond counter, so it's converted to a
# percent-of-period-busy figure via metric math before the same MAX-based
# comparison.
###############################################################################

module "ec2_diskio_warn" {
  source   = "terraform-aws-modules/cloudwatch/aws//modules/metric-alarm"
  version  = "5.7.1"
  for_each = local.ec2_diskio_instances

  alarm_name          = "HighDiskIOWait-Warn-${each.key}"
  alarm_description   = "Triggers if EC2 instance ${each.value.instance_id} disk I/O busy time exceeds ${var.ec2_diskio_warn_threshold_percent}%"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = var.ec2_diskio_evaluation_periods
  threshold           = var.ec2_diskio_warn_threshold_percent
  treat_missing_data  = "missing"

  metric_query = each.value.os_type == "windows" ? [
    {
      id          = "io_wait"
      expression  = "MAX(SEARCH('{CWAgent,InstanceId} MetricName=\"% Disk Time\" InstanceId=\"${each.value.instance_id}\"', 'Average', ${var.ec2_diskio_period_seconds}))"
      label       = "DiskIOWaitPercent"
      return_data = "true"
    },
    ] : [
    {
      id          = "io_ms"
      expression  = "MAX(SEARCH('{CWAgent,InstanceId} MetricName=\"diskio_io_time\" InstanceId=\"${each.value.instance_id}\"', 'Sum', ${var.ec2_diskio_period_seconds}))"
      label       = "DiskIOBusyMs"
      return_data = "false"
    },
    {
      id          = "io_wait"
      expression  = "(io_ms / (${var.ec2_diskio_period_seconds} * 1000)) * 100"
      label       = "DiskIOWaitPercent"
      return_data = "true"
    },
  ]

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
  evaluation_periods  = var.ec2_diskio_evaluation_periods
  threshold           = var.ec2_diskio_crit_threshold_percent
  treat_missing_data  = "missing"

  metric_query = each.value.os_type == "windows" ? [
    {
      id          = "io_wait"
      expression  = "MAX(SEARCH('{CWAgent,InstanceId} MetricName=\"% Disk Time\" InstanceId=\"${each.value.instance_id}\"', 'Average', ${var.ec2_diskio_period_seconds}))"
      label       = "DiskIOWaitPercent"
      return_data = "true"
    },
    ] : [
    {
      id          = "io_ms"
      expression  = "MAX(SEARCH('{CWAgent,InstanceId} MetricName=\"diskio_io_time\" InstanceId=\"${each.value.instance_id}\"', 'Sum', ${var.ec2_diskio_period_seconds}))"
      label       = "DiskIOBusyMs"
      return_data = "false"
    },
    {
      id          = "io_wait"
      expression  = "(io_ms / (${var.ec2_diskio_period_seconds} * 1000)) * 100"
      label       = "DiskIOWaitPercent"
      return_data = "true"
    },
  ]

  alarm_actions = [var.sns_topic_arns.critical_alarm_arn]
  ok_actions    = [var.sns_topic_arns.critical_ok_arn]

  tags = local.tags_crit
}

###############################################################################
# EC2 network errors - Windows only for now (see var.ec2_instances
# description; Linux CWAgent net error counters aren't collected yet by
# msi-terraform-cloudwatch-agent). Summed as a raw count like the ALB 5xx
# alarms, not a rate. Assumes one active network interface per instance.
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
      id          = "received_errors"
      metric_name = "Packets Received Errors"
      namespace   = "CWAgent"
      period      = var.ec2_network_errors_period_seconds
      stat        = "Sum"
      dimensions = {
        InstanceId = each.value.instance_id
      }
    },
    {
      id          = "outbound_errors"
      metric_name = "Packets Outbound Errors"
      namespace   = "CWAgent"
      period      = var.ec2_network_errors_period_seconds
      stat        = "Sum"
      dimensions = {
        InstanceId = each.value.instance_id
      }
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
      id          = "received_errors"
      metric_name = "Packets Received Errors"
      namespace   = "CWAgent"
      period      = var.ec2_network_errors_period_seconds
      stat        = "Sum"
      dimensions = {
        InstanceId = each.value.instance_id
      }
    },
    {
      id          = "outbound_errors"
      metric_name = "Packets Outbound Errors"
      namespace   = "CWAgent"
      period      = var.ec2_network_errors_period_seconds
      stat        = "Sum"
      dimensions = {
        InstanceId = each.value.instance_id
      }
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
