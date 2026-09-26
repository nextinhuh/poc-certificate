resource "aws_cloudwatch_log_group" "step_ca" {
  name              = "/ecs/${var.project_name}-step-ca"
  retention_in_days = 3
}

resource "aws_ecs_task_definition" "step_ca" {
  family                   = "${var.project_name}-step-ca"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                       = "256"
  memory                    = "512"
  execution_role_arn        = data.aws_iam_role.ecs_execution.arn
  task_role_arn             = aws_iam_role.step_ca_task.arn

  volume {
    name = "step-ca-home"

    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.step_ca.id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = aws_efs_access_point.step_ca.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([
    {
      name      = "step-ca"
      image     = "${data.aws_ecr_repository.this.repository_url}:${var.image_tag}"
      essential = true
      portMappings = [{ containerPort = 9000, protocol = "tcp" }]

      mountPoints = [{
        sourceVolume  = "step-ca-home"
        containerPath = "/home/step"
      }]

      environment = [
        { name = "STEPPATH", value = "/home/step" },
        { name = "CA_DNS", value = "localhost" },
        { name = "CA_ADDRESS", value = ":9000" },
        { name = "KEYCLOAK_ISSUER", value = "http://keycloak.${var.project_name}.local:8080/realms/poc-terminal" },
        { name = "OIDC_CLIENT_ID", value = "step-ca-oidc" },
        { name = "ROOT_CA_BUCKET", value = aws_s3_bucket.root_ca.bucket },
      ]

      secrets = [
        {
          name      = "OIDC_CLIENT_SECRET"
          valueFrom = data.aws_ssm_parameter.stepca_client_secret.arn
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.step_ca.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "step-ca"
        }
      }
    }
  ])
}

resource "aws_lb_target_group" "step_ca" {
  name        = "${var.project_name}-step-ca-tg"
  port        = 9000
  # step-ca sempre serve HTTPS (com o proprio certificado interno da CA,
  # autoassinado) - nunca HTTP puro. O ALB, para target groups HTTPS, NAO
  # valida o certificado apresentado pelo target, entao isso funciona sem
  # nenhum certificado "de verdade" no backend.
  protocol    = "HTTPS"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"

  health_check {
    protocol            = "HTTPS"
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
  }
}

resource "aws_lb_listener_rule" "step_ca_sign" {
  listener_arn = data.aws_lb_listener.http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.step_ca.arn
  }

  condition {
    path_pattern {
      values = ["/1.0/sign", "/health"]
    }
  }
}

resource "aws_ecs_service" "step_ca" {
  name            = "${var.project_name}-step-ca"
  cluster         = data.aws_ecs_cluster.this.arn
  task_definition = aws_ecs_task_definition.step_ca.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = data.aws_subnets.public.ids
    security_groups  = [data.aws_security_group.ecs_tasks.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.step_ca.arn
    container_name    = "step-ca"
    container_port    = 9000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener_rule.step_ca_sign]
}
