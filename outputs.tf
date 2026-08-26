output "alarm_arns" {
  description = <<-EOT
    Map of every CloudWatch alarm ARN created by this module, keyed by a
    unique alarm identifier ("<category>-<tier>-<resource-key>"). Intended
    for consumption by the sibling msi-terraform-cloudwatch-composite-alarms
    module.
  EOT
  value = merge(
    { for k, v in module.ecs_cpu_utilization_warn : "ecs-cpu-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ecs_cpu_utilization_crit : "ecs-cpu-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ecs_memory_utilization_warn : "ecs-memory-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ecs_memory_utilization_crit : "ecs-memory-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ecs_container_restart_warn : "ecs-restart-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ecs_container_restart_crit : "ecs-restart-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.alb_5xx_warn : "alb-5xx-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.alb_5xx_crit : "alb-5xx-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.alb_latency_warn : "alb-latency-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.alb_latency_crit : "alb-latency-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_cpu_utilization_warn : "ec2-cpu-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_cpu_utilization_crit : "ec2-cpu-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_memory_utilization_warn : "ec2-memory-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_memory_utilization_crit : "ec2-memory-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_disk_usage_warn : "ec2-disk-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_disk_usage_crit : "ec2-disk-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_diskio_warn : "ec2-diskio-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_diskio_crit : "ec2-diskio-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_network_errors_warn : "ec2-network-errors-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_network_errors_crit : "ec2-network-errors-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.ec2_status_check_failed : "ec2-status-check-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.lambda_error_rate_warn : "lambda-error-rate-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.lambda_error_rate_crit : "lambda-error-rate-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.lambda_duration_warn : "lambda-duration-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.lambda_duration_crit : "lambda-duration-crit-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.lambda_throttles : "lambda-throttles-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.lambda_concurrency_warn : "lambda-concurrency-warn-${k}" => v.cloudwatch_metric_alarm_arn },
    { for k, v in module.lambda_concurrency_crit : "lambda-concurrency-crit-${k}" => v.cloudwatch_metric_alarm_arn },
  )
}
