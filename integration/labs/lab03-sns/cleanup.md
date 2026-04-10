# Lab 03 — Cleanup

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Eliminar suscripciones y topics
for topic_name in lab03-pedidos lab03-pedidos-filtered lab03-sns-pedidos; do
  ARN="arn:aws:sns:$REGION:$ACCOUNT_ID:$topic_name"
  for sub in $(aws sns list-subscriptions-by-topic --topic-arn "$ARN" --region "$REGION" \
    --query 'Subscriptions[*].SubscriptionArn' --output text 2>/dev/null); do
    aws sns unsubscribe --subscription-arn "$sub" --region "$REGION" 2>/dev/null || true
  done
  aws sns delete-topic --topic-arn "$ARN" --region "$REGION" 2>/dev/null && echo "Deleted topic: $topic_name" || true
done

# Eliminar queues
for q in lab03-inventario lab03-facturacion lab03-email lab03-domestic lab03-international lab03-vip \
         lab03-sns-inventario lab03-sns-facturacion lab03-sns-email; do
  URL="https://sqs.$REGION.amazonaws.com/$ACCOUNT_ID/$q"
  aws sqs delete-queue --queue-url "$URL" --region "$REGION" 2>/dev/null && echo "Deleted: $q" || true
done

# Si usaste Terraform
# cd integration/labs/lab03-sns/terraform && terraform destroy -auto-approve
```
