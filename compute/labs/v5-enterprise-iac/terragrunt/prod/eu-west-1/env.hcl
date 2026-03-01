################################################################################
# env.hcl — Variables específicas del entorno prod / eu-west-1
################################################################################

locals {
  environment = "prod"
  aws_region  = "eu-west-1"
  project     = "ec2lab"

  vpc_cidr              = "10.1.0.0/16"
  public_subnets_cidrs  = ["10.1.1.0/24", "10.1.2.0/24", "10.1.3.0/24"]
  private_subnets_cidrs = ["10.1.11.0/24", "10.1.12.0/24", "10.1.13.0/24"]

  instance_type        = "t3.small"
  asg_min_size         = 2
  asg_max_size         = 10
  asg_desired_capacity = 2
  single_nat_gateway   = false   # Prod: 1 NAT por AZ para HA

  db_instance_class = "db.t3.medium"
  redis_node_type   = "cache.t3.micro"
}
