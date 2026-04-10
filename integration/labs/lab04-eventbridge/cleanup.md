# Lab 04 — Cleanup

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Eliminar targets y reglas en cada bus
for bus in lab04-eventos lab04-central-bus lab04-workload-bus lab04-eb-main; do
  for rule in $(aws events list-rules --event-bus-name "$bus" --region "$REGION" \
    --query 'Rules[*].Name' --output text 2>/dev/null); do
    for target in $(aws events list-targets-by-rule --rule "$rule" --event-bus-name "$bus" \
      --region "$REGION" --query 'Targets[*].Id' --output text 2>/dev/null); do
      aws events remove-targets --rule "$rule" --event-bus-name "$bus" --ids "$target" --region "$REGION" 2>/dev/null || true
    done
    aws events delete-rule --name "$rule" --event-bus-name "$bus" --region "$REGION" 2>/dev/null || true
  done
  aws events delete-event-bus --name "$bus" --region "$REGION" 2>/dev/null && echo "Deleted bus: $bus" || true
done

# SQS queues
for q in lab04-high-value-orders lab04-international-orders lab04-eb-high-value lab04-eb-international; do
  URL="https://sqs.$REGION.amazonaws.com/$ACCOUNT_ID/$q"
  aws sqs delete-queue --queue-url "$URL" --region "$REGION" 2>/dev/null && echo "Deleted: $q" || true
done

# CloudWatch Logs
for lg in /aws/events/lab04-eventos /aws/events/lab04-central-bus /aws/events/lab04-eb-main; do
  aws logs delete-log-group --log-group-name "$lg" --region "$REGION" 2>/dev/null || true
done

# IAM
aws iam delete-role-policy --role-name lab04-eventbridge-cross-bus-role --policy-name put-events-to-central 2>/dev/null || true
aws iam delete-role --role-name lab04-eventbridge-cross-bus-role 2>/dev/null || true

# Si usaste Terraform
# cd integration/labs/lab04-eventbridge/terraform && terraform destroy -auto-approve
```
