resource "aws_ecs_cluster" "aggregator" {
  name = "aggregator"
}

resource "aws_ecs_cluster_capacity_providers" "aggregator" {
  cluster_name       = aws_ecs_cluster.aggregator.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

resource "aws_autoscaling_group" "aggregator_cluster" {
  name                = local.aggregator_cluster_name
  vpc_zone_identifier = data.aws_subnets.main.ids
  min_size            = 3
  max_size            = 3
  desired_capacity    = 3

  capacity_rebalance = true

  mixed_instances_policy {
    instances_distribution {
      # Guarantee 1 on-demand instance, the other 2 come from Spots when available
      on_demand_base_capacity                  = 1
      on_demand_percentage_above_base_capacity = 0
      spot_allocation_strategy                 = "price-capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.aggregator_cluster.id
        version            = "$Latest"
      }
      override {
        instance_type = "t4g.small"
      }
      override {
        instance_type = "t4g.medium"
      }
      override {
        instance_type = "t4g.large"
      }
      override {
        instance_type = "m6g.large"
      }
      override {
        instance_type = "m7g.large"
      }
      override {
        instance_type = "c6g.large"
      }
      override {
        instance_type = "c7g.large"
      }
    }
  }

  dynamic "tag" {
    for_each = [
      {
        key   = "Name"
        value = "aggregator"
      },
      {
        key   = "application"
        value = "aggregator"
      },
      {
        key   = "environment"
        value = "production"
      },
    ]
    content {
      key                 = tag.value.key
      value               = tag.value.value
      propagate_at_launch = true
    }
  }
}

locals {
  aggregator_cluster_name = aws_ecs_cluster.aggregator.name
}

resource "aws_launch_template" "aggregator_cluster" {
  name_prefix            = local.aggregator_cluster_name
  image_id               = data.aws_ami.ecs.image_id
  instance_type          = "t4g.small"
  key_name               = data.aws_key_pair.this.key_name
  user_data              = data.cloudinit_config.aggregator_cluster.rendered
  update_default_version = true

  iam_instance_profile {
    name = data.aws_iam_instance_profile.ecs.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [data.aws_security_group.ecs_clusters.id]
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = 30
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "aggregator"
      application = "true"
      environment = "production"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name        = "aggregator"
      application = "true"
      environment = "production"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}
