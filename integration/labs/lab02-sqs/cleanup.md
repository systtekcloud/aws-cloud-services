# Lab 02 — Cleanup

```bash
# Queues del lab
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

for queue in lab02-standard lab02-standard-dlq lab02-fifo.fifo lab02-fifo-dlq.fifo lab02-visibility-demo lab02-main-with-dlq lab02-main-dlq lab02-sqs-standard lab02-sqs-standard-dlq lab02-sqs-fifo.fifo lab02-sqs-fifo-dlq.fifo; do
  URL="https://sqs.$REGION.amazonaws.com/$ACCOUNT_ID/$queue"
  aws sqs delete-queue --queue-url "$URL" --region "$REGION" 2>/dev/null && echo "Deleted: $queue" || true
done

# Alarmas CloudWatch
aws cloudwatch delete-alarms \
  --alarm-names "lab02-dlq-has-messages" "lab02-sqs-standard-dlq-depth" "lab02-sqs-fifo-dlq-depth" \
  --region "$REGION" 2>/dev/null || true

# Si usaste Terraform
# cd integration/labs/lab02-sqs/terraform && terraform destroy -auto-approve
```
