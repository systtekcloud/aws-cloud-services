# Lab 05 — Cleanup

```bash
REGION="eu-west-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# State machines
for sm in lab05-pedido-workflow lab05-error-handling lab05-timeout-demo lab05-distributed-map lab05-saga-viaje lab05-sfn-standard-workflow lab05-sfn-express-workflow; do
  ARN=$(aws stepfunctions list-state-machines --region "$REGION" \
    --query "stateMachines[?name=='$sm'].stateMachineArn" --output text 2>/dev/null)
  [ -n "$ARN" ] && aws stepfunctions delete-state-machine --state-machine-arn "$ARN" --region "$REGION" && echo "Deleted: $sm" || true
done

# Lambda functions
for fn in lab05-validar-pedido lab05-procesar-pago lab05-enviar-confirmacion \
          lab05-slow-function lab05-map-processor lab05-saga-reserve lab05-saga-cancel \
          lab05-sfn-validar lab05-sfn-procesar; do
  aws lambda delete-function --function-name "$fn" --region "$REGION" 2>/dev/null && echo "Deleted: $fn" || true
done

# IAM
for role in lab05-sfn-role lab05-sfn-lambda-role lab05-sfn-sfn-role; do
  for pol in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames' --output text 2>/dev/null); do
    aws iam delete-role-policy --role-name "$role" --policy-name "$pol" 2>/dev/null || true
  done
  for arn in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null); do
    aws iam detach-role-policy --role-name "$role" --policy-arn "$arn" 2>/dev/null || true
  done
  aws iam delete-role --role-name "$role" 2>/dev/null && echo "Deleted role: $role" || true
done

# CloudWatch Log Groups
aws logs delete-log-group --log-group-name "/aws/states/lab05-sfn-workflow" --region "$REGION" 2>/dev/null || true

# S3 (Distributed Map)
BUCKET="lab05-distributed-map-$ACCOUNT_ID"
aws s3 rm "s3://$BUCKET" --recursive --region "$REGION" 2>/dev/null || true
aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null && echo "Deleted bucket: $BUCKET" || true

# Si usaste Terraform
# cd integration/labs/lab05-step-functions/terraform && terraform destroy -auto-approve
```
