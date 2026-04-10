# Lab 06 — Cleanup

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# REST APIs
for name in lab06-rest-api lab06-apigw-rest; do
  ID=$(aws apigateway get-rest-apis --region "$REGION" \
    --query "items[?name=='$name'].id" --output text 2>/dev/null)
  [ -n "$ID" ] && aws apigateway delete-rest-api --rest-api-id "$ID" --region "$REGION" && echo "Deleted REST API: $name" || true
done

# HTTP APIs
for name in lab06-http-api lab06-apigw-http; do
  ID=$(aws apigatewayv2 get-apis --region "$REGION" \
    --query "Items[?Name=='$name'].ApiId" --output text 2>/dev/null)
  [ -n "$ID" ] && aws apigatewayv2 delete-api --api-id "$ID" --region "$REGION" && echo "Deleted HTTP API: $name" || true
done

# Lambda functions
for fn in lab06-apigw-handler lab06-authorizer lab06-apigw-backend lab06-apigw-authorizer; do
  aws lambda delete-function --function-name "$fn" --region "$REGION" 2>/dev/null && echo "Deleted: $fn" || true
done

# API Keys
for key_id in $(aws apigateway get-api-keys --region "$REGION" \
  --query "items[?starts_with(name, 'lab06')].id" --output text 2>/dev/null); do
  aws apigateway delete-api-key --api-key "$key_id" --region "$REGION" 2>/dev/null || true
done

# IAM
for role in lab06-apigw-lambda-role; do
  for pol in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$pol" 2>/dev/null || true
  done
  for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$role" 2>/dev/null && echo "Deleted role: $role" || true
done

# Si usaste Terraform
# cd integration/labs/lab06-api-gateway/terraform && terraform destroy -auto-approve
```
