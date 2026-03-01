################################################################################
# Lab EC2 v3 — Terraform
# Resiliencia: Warm Pool + Step Scaling + Blue/Green Weighted TGs
################################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws"; version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = var.project; Lab = "v3"; ManagedBy = "Terraform"; Environment = var.environment }
  }
}

locals { name_prefix = "${var.project}-${var.environment}" }

################################################################################
# Warm Pool
################################################################################

resource "aws_autoscaling_group_tag" "warm_pool_marker" {
  autoscaling_group_name = var.asg_name
  tag { key = "WarmPool"; value = "enabled"; propagate_at_launch = false }
}

resource "awscc_autoscaling_warm_pool" "app" {
  # NOTA: Este recurso requiere el provider awscc. Alternativa con CLI:
  # aws autoscaling put-warm-pool --auto-scaling-group-name <name> --pool-state Stopped --min-size 2
  #
  # Con provider aws estándar, usar null_resource + local-exec como workaround:
  # ver cli/02-warm-pool.sh para la solución directa con CLI.
}

# Workaround con aws_autoscaling_lifecycle_hook para indicar Warm Pool readiness
resource "aws_autoscaling_lifecycle_hook" "warm_pool_ready" {
  name                   = "${local.name_prefix}-warm-pool-ready"
  autoscaling_group_name = var.asg_name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  default_result         = "CONTINUE"
  heartbeat_timeout      = 120
}

################################################################################
# Step Scaling Policies
################################################################################

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.asg_name}-cpu-high"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 1
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_description   = "CPU > 80% — scale out agresivo"

  dimensions = { AutoScalingGroupName = var.asg_name }
  alarm_actions = [aws_autoscaling_policy.step_scale_out.arn]
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.asg_name}-cpu-low"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 20
  comparison_operator = "LessThanThreshold"
  alarm_description   = "CPU < 20% durante 15 min — scale in"

  dimensions = { AutoScalingGroupName = var.asg_name }
  alarm_actions = [aws_autoscaling_policy.step_scale_in.arn]
}

resource "aws_autoscaling_policy" "step_scale_out" {
  name                   = "${var.asg_name}-step-scale-out"
  autoscaling_group_name = var.asg_name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"
  estimated_instance_warmup = 120

  step_adjustment {
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 10
    scaling_adjustment          = 1
  }
  step_adjustment {
    metric_interval_lower_bound = 10
    scaling_adjustment          = 2
  }
}

resource "aws_autoscaling_policy" "step_scale_in" {
  name                   = "${var.asg_name}-step-scale-in"
  autoscaling_group_name = var.asg_name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    metric_interval_upper_bound = 0
    scaling_adjustment          = -1
  }
}

################################################################################
# Scheduled Scaling
################################################################################

resource "aws_autoscaling_schedule" "pico_manana" {
  scheduled_action_name  = "pico-manana"
  autoscaling_group_name = var.asg_name
  recurrence             = "0 8 * * 1-5"
  min_size               = 4
  max_size               = 10
  desired_capacity       = 4
}

resource "aws_autoscaling_schedule" "pico_tarde" {
  scheduled_action_name  = "pico-tarde"
  autoscaling_group_name = var.asg_name
  recurrence             = "0 20 * * 1-5"
  min_size               = 2
  max_size               = 6
  desired_capacity       = 2
}

################################################################################
# Blue/Green — Target Group Green + Listener weighted forward
################################################################################

resource "aws_lb_target_group" "green" {
  name        = "${local.name_prefix}-tg-green"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${local.name_prefix}-tg-green"; Env = "green" }
}

resource "aws_autoscaling_group" "green" {
  name             = "${local.name_prefix}-asg-green"
  min_size         = 1
  max_size         = 4
  desired_capacity = 2

  vpc_zone_identifier = var.private_subnet_ids
  health_check_type   = "ELB"
  health_check_grace_period = 120
  target_group_arns   = [aws_lb_target_group.green.arn]

  launch_template {
    id      = var.launch_template_id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${local.name_prefix}-app-green"
    propagate_at_launch = true
  }
  tag {
    key                 = "Env"
    value               = "green"
    propagate_at_launch = true
  }

  lifecycle { create_before_destroy = true }
}

# Canary: 90% Blue / 10% Green
resource "aws_lb_listener_rule" "canary" {
  listener_arn = var.alb_listener_arn
  priority     = 1

  action {
    type = "forward"
    forward {
      target_group {
        arn    = var.tg_blue_arn
        weight = 90
      }
      target_group {
        arn    = aws_lb_target_group.green.arn
        weight = 10
      }
    }
  }

  condition {
    path_pattern { values = ["/*"] }
  }
}
