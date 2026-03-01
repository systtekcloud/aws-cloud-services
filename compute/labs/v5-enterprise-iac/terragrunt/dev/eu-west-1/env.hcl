################################################################################
# env.hcl — Variables específicas del entorno dev / eu-west-1
################################################################################

locals {
  environment = "dev"
  aws_region  = "eu-west-1"
  project     = "ec2lab"

  # CIDRs del entorno
  vpc_cidr              = "10.0.0.0/16"
  public_subnets_cidrs  = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  private_subnets_cidrs = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]

  # EC2
  instance_type        = "t3.micro"
  asg_min_size         = 1
  asg_max_size         = 4
  asg_desired_capacity = 1
  single_nat_gateway   = true   # Dev: 1 NAT para ahorrar coste

  # DB
  db_instance_class = "db.t3.medium"
  redis_node_type   = "cache.t3.micro"
}
