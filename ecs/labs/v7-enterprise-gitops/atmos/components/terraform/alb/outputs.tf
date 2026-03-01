output "alb_arn"                 { value = module.alb.alb_arn }
output "alb_dns_name"            { value = module.alb.alb_dns_name }
output "alb_zone_id"             { value = module.alb.alb_zone_id }
output "alb_arn_suffix"          { value = module.alb.alb_arn_suffix }
output "target_group_arn"        { value = module.alb.target_group_arn }
output "target_group_arn_suffix" { value = module.alb.target_group_arn_suffix }
output "alb_security_group_id"   { value = module.alb.alb_security_group_id }
output "listener_arn"            { value = module.alb.listener_arn }
