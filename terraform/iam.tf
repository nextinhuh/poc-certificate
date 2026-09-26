# A EFS IAM authorization (authorization_config.iam = "ENABLED" no volume,
# ver ecs.tf) exige uma task role propria - diferente da execution role
# (que so serve pra ECS Agent puxar imagem/segredos/logs). Sem essa role, o
# RegisterTaskDefinition falha com "EFS IAM authorization requires a task role".
resource "aws_iam_role" "step_ca_task" {
  name = "${var.project_name}-step-ca-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "step_ca_task" {
  name = "${var.project_name}-step-ca-task"
  role = aws_iam_role.step_ca_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:DescribeMountTargets",
        ]
        Resource = aws_efs_file_system.step_ca.arn
        Condition = {
          StringEquals = {
            "elasticfilesystem:AccessPointArn" = aws_efs_access_point.step_ca.arn
          }
        }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.root_ca.arn}/*"
      },
    ]
  })
}
