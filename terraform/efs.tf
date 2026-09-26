resource "aws_efs_file_system" "step_ca" {
  encrypted = true

  tags = {
    Name = "${var.project_name}-step-ca-efs"
  }
}

resource "aws_efs_mount_target" "step_ca" {
  for_each = toset(data.aws_subnets.public.ids)

  file_system_id  = aws_efs_file_system.step_ca.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_security_group" "efs" {
  name        = "${var.project_name}-step-ca-efs-sg"
  description = "Permite NFS (2049) das tasks do step-ca"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [data.aws_security_group.ecs_tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Access point restrito - so expoe /home/step (certs + db do CA), sem acesso
# a mais nada no file system.
resource "aws_efs_access_point" "step_ca" {
  file_system_id = aws_efs_file_system.step_ca.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/step-ca-home"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "700"
    }
  }
}
