resource "aws_db_subnet_group" "aggregator" {
  name       = "aggregator"
  subnet_ids = data.aws_subnets.main.ids
}

resource "aws_db_instance" "aggregator" {
  identifier          = "aggregator"
  allocated_storage   = 100
  engine              = "mysql"
  engine_version      = "8.0.40"
  instance_class      = "db.t3.micro"
  storage_type        = "gp2"
  deletion_protection = true
  multi_az            = false
  db_name             = "aggregator"
  username            = "aggregator"
  password            = var.rds_password
  port                = 3306

  apply_immediately       = true
  publicly_accessible     = true
  vpc_security_group_ids  = [data.aws_security_group.rds_mysql.id]
  db_subnet_group_name    = aws_db_subnet_group.aggregator.name
  backup_retention_period = 7

  skip_final_snapshot = false

  tags = {
    Name = "aggregator"
  }

  lifecycle {
    ignore_changes = [snapshot_identifier]
  }
}
