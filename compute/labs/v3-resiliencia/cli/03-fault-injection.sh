#!/usr/bin/env bash
# v3 — CLI 03: AWS Fault Injection Simulator — terminar instancias EC2
# Prueba que el ASG repone instancias automáticamente desde el Warm Pool
set -euo pipefail

source ~/.ec2-lab-env

echo "=== v3: Configurando FIS experiment ==="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# IAM Role para FIS
cat > /tmp/fis-trust-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "fis.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
EOF

FIS_ROLE_ARN=$(aws iam create-role \
  --role-name "${PROJECT}-fis-role" \
  --assume-role-policy-document file:///tmp/fis-trust-policy.json \
  --query 'Role.Arn' --output text 2>/dev/null || \
  aws iam get-role --role-name "${PROJECT}-fis-role" \
  --query 'Role.Arn' --output text)

# Política para FIS: solo terminar EC2 con tag del lab
cat > /tmp/fis-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["ec2:TerminateInstances"],
    "Resource": "*",
    "Condition": {
      "StringEquals": {
        "aws:ResourceTag/Project": "${PROJECT}"
      }
    }
  }]
}
EOF

aws iam put-role-policy \
  --role-name "${PROJECT}-fis-role" \
  --policy-name "fis-terminate-ec2" \
  --policy-document file:///tmp/fis-policy.json

echo "IAM Role FIS: $FIS_ROLE_ARN"

# Experimento: terminar 1 instancia aleatoria del ASG
EXPERIMENT_TEMPLATE=$(aws fis create-experiment-template \
  --description "Terminar 1 instancia EC2 del ASG — test resiliencia" \
  --role-arn "$FIS_ROLE_ARN" \
  --stop-conditions '[{"source":"none"}]' \
  --actions '{
    "TerminateEC2": {
      "actionId": "aws:ec2:terminate-instances",
      "parameters": {},
      "targets": {"Instances": "asg-instances"}
    }
  }' \
  --targets '{
    "asg-instances": {
      "resourceType": "aws:ec2:instance",
      "resourceTags": {"Project": "'"$PROJECT"'", "Lab": "v1"},
      "selectionMode": "COUNT(1)"
    }
  }' \
  --query 'experimentTemplate.id' --output text)

echo "Experiment template creado: $EXPERIMENT_TEMPLATE"

cat >> ~/.ec2-lab-env << EOF

# v3 — FIS
export FIS_ROLE_ARN="$FIS_ROLE_ARN"
export FIS_TEMPLATE_ID="$EXPERIMENT_TEMPLATE"
EOF

echo ""
echo "Para ejecutar el experimento:"
echo "  EXPERIMENT_ID=\$(aws fis start-experiment \\"
echo "    --experiment-template-id $EXPERIMENT_TEMPLATE \\"
echo "    --query 'experiment.id' --output text)"
echo ""
echo "  # Monitorizar recuperación:"
echo "  watch -n5 'aws autoscaling describe-auto-scaling-groups \\"
echo "    --auto-scaling-group-names $ASG_NAME \\"
echo "    --query \"AutoScalingGroups[0].Instances[*].[InstanceId,LifecycleState,HealthStatus]\" \\"
echo "    --output table'"

echo "=== FIS configurado ==="
