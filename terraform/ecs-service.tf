resource "aws_ecs_task_definition" "aggregator" {
  family             = "aggregator"
  task_role_arn      = data.aws_iam_role.ecs_task.arn
  execution_role_arn = data.aws_iam_role.ecs_task.arn

  container_definitions = jsonencode(
    [
      {
        name = "aggregator"
        portMappings = [
          {
            hostPort      = 0
            containerPort = 8000
            protocol      = "tcp"
          }
        ]
        essential = true
        dependsOn = [
          {
            "containerName" : "aggregator-init"
            "condition" : "COMPLETE"
          }
        ]
        environment = [
          {
            name  = "GOOGLE_API_KEY"
            value = var.GOOGLE_API_KEY
          },
          {
            name  = "AGGREGATOR_MODE_ENABLED"
            value = "true"
          },
          {
            name  = "AGGREGATOR_MAX_GEO_WIDTH_KM"
            value = "160"
          },
          {
            name  = "NEW_UI_ENABLED"
            value = "false"
          },
          {
            name  = "DB_DATABASE"
            value = "aggregator"
          },
          {
            name  = "DB_USER"
            value = "aggregator"
          },
          {
            name  = "DB_USERNAME"
            value = "aggregator"
          },
          {
            name  = "DB_PASSWORD"
            value = var.rds_password
          },
          {
            name  = "DB_HOST"
            value = aws_db_instance.bmlt_aggregator.address
          },
          {
            name  = "DB_PREFIX"
            value = "na"
          }
        ]
        workingDirectory = "/tmp"
        image            = "bmltenabled/bmlt-server:aggregator"
        imagePullPolicy  = "ALWAYS"
        repositoryCredentials = {
          credentialsParameter = data.aws_secretsmanager_secret.docker.arn
        }
        command = [
          "apachectl",
          "-D",
          "FOREGROUND"
        ]
        logConfiguration = {
          logDriver = "awslogs",
          options = {
            awslogs-group         = aws_cloudwatch_log_group.aggregator.name
            awslogs-region        = "us-east-1"
            awslogs-stream-prefix = "aggregator"
          }
        }
        memoryReservation = 1280
        linuxParameters = {
          initProcessEnabled = true
        }
      },
      {
        name = "aggregator-init"
        portMappings = [
          {
            hostPort      = 0
            containerPort = 8000
            protocol      = "tcp"
          }
        ]
        essential = false
        environment = [
          {
            name  = "GKEY"
            value = var.GOOGLE_API_KEY
          },
          {
            name  = "LOG_CHANNEL"
            value = "errorlog"
          },
          {
            name  = "AGGREGATOR_MODE_ENABLED"
            value = "true"
          },
          {
            name  = "NEW_UI_ENABLED"
            value = "false"
          },
          {
            name  = "DB_DATABASE"
            value = "aggregator"
          },
          {
            name  = "DB_USERNAME"
            value = "aggregator"
          },
          {
            name  = "DB_USER"
            value = "aggregator"
          },
          {
            name  = "DB_PASSWORD"
            value = var.rds_password
          },
          {
            name  = "DB_HOST"
            value = aws_db_instance.bmlt_aggregator.address
          },
          {
            name  = "DB_PREFIX"
            value = "na"
          }
        ]
        workingDirectory = "/tmp"
        image            = "bmltenabled/bmlt-server:aggregator"
        imagePullPolicy  = "ALWAYS"
        repositoryCredentials = {
          credentialsParameter = data.aws_secretsmanager_secret.docker.arn
        },
        command = [
          "/usr/bin/php",
          "/var/www/html/main_server/artisan",
          "aggregator:InitializeDatabase"
        ]
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.aggregator_init.name
            awslogs-region        = "us-east-1"
            awslogs-stream-prefix = "init"
          }
        }
        memoryReservation = 256
        linuxParameters = {
          initProcessEnabled = true
        }
      }
    ]
  )
}

resource "aws_ecs_task_definition" "aggregator_import" {
  family             = "aggregator-import"
  task_role_arn      = data.aws_iam_role.ecs_task.arn
  execution_role_arn = data.aws_iam_role.ecs_task.arn

  container_definitions = jsonencode(
    [
      {
        name = "aggregator-import"
        portMappings = [
          {
            hostPort      = 0
            containerPort = 8000
            protocol      = "tcp"
          }
        ]
        essential = true
        environment = [
          {
            name  = "GOOGLE_API_KEY"
            value = var.GOOGLE_API_KEY
          },
          {
            name  = "AGGREGATOR_MODE_ENABLED"
            value = "true"
          },
          {
            name  = "AGGREGATOR_USER_AGENT"
            value = "Mozilla/5.0 (X11; Linux x86_64; rv:146.0) Gecko/20100101 Firefox/146.0 +aggregator"
          },
          {
            name  = "LOG_CHANNEL"
            value = "errorlog"
          },
          {
            name  = "NEW_UI_ENABLED"
            value = "false"
          },
          {
            name  = "DB_DATABASE"
            value = "aggregator"
          },
          {
            name  = "DB_USER"
            value = "aggregator"
          },
          {
            name  = "DB_USERNAME"
            value = "aggregator"
          },
          {
            name  = "DB_PASSWORD"
            value = var.rds_password
          },
          {
            name  = "DB_HOST"
            value = aws_db_instance.bmlt_aggregator.address
          },
          {
            name  = "DB_PREFIX"
            value = "na"
          }
        ]
        workingDirectory = "/tmp"
        image            = "bmltenabled/bmlt-server:aggregator"
        imagePullPolicy  = "ALWAYS"
        repositoryCredentials = {
          credentialsParameter = data.aws_secretsmanager_secret.docker.arn
        }
        command = [
          "/usr/bin/php",
          "/var/www/html/main_server/artisan",
          "aggregator:ImportRootServers"
        ]
        logConfiguration = {
          logDriver = "awslogs"
          options = {
            awslogs-group         = aws_cloudwatch_log_group.aggregator_import.name
            awslogs-region        = "us-east-1"
            awslogs-stream-prefix = "daemon"
          }
        }
        memoryReservation = 320
        linuxParameters = {
          initProcessEnabled = true
        }
      }
    ]
  )
}

resource "aws_ecs_service" "aggregator" {
  name                               = "aggregator"
  cluster                            = aws_ecs_cluster.aggregator.id
  desired_count                      = 2
  iam_role                           = data.aws_iam_role.ecs_service.name
  task_definition                    = aws_ecs_task_definition.aggregator.arn
  enable_execute_command             = true
  deployment_minimum_healthy_percent = 50

  load_balancer {
    target_group_arn = aws_lb_target_group.aggregator.id
    container_name   = "aggregator"
    container_port   = 8000
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  lifecycle {
    ignore_changes = [task_definition]
  }
}
