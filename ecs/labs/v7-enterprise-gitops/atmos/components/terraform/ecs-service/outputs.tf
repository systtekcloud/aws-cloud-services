output "service_name"        { value = module.ecs_service.service_name }
output "service_arn"         { value = module.ecs_service.service_arn }
output "task_definition_arn" { value = module.ecs_service.task_definition_arn }
output "security_group_id"   { value = module.ecs_service.security_group_id }
output "execution_role_arn"  { value = module.ecs_service.execution_role_arn }
output "task_role_arn"        { value = module.ecs_service.task_role_arn }
output "log_group_name"       { value = module.ecs_service.log_group_name }
output "sns_topic_arn"        { value = module.ecs_service.sns_topic_arn }
