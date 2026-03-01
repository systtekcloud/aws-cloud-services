output "sqs_queue_url"   { value = aws_sqs_queue.orders.url }
output "sqs_dlq_url"     { value = aws_sqs_queue.orders_dlq.url }
output "worker_service"  { value = aws_ecs_service.worker.id }

output "cmd_send_test_message" {
  description = "Enviar un mensaje de prueba a SQS para disparar el worker"
  value       = "aws sqs send-message --queue-url ${aws_sqs_queue.orders.url} --message-body '{\"product_id\":\"p001\",\"quantity\":2,\"customer_id\":\"cust-123\"}'"
}

output "cmd_watch_workers" {
  description = "Monitorear el número de workers corriendo"
  value       = "watch -n10 'aws ecs describe-services --cluster shopapi-cluster --services shopapi-worker --query \"services[0].{running:runningCount,desired:desiredCount,pending:pendingCount}\" --output table'"
}
