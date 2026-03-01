#!/usr/bin/env bash
# =============================================================================
# v1 — Paso 3: Security Groups, Launch Template, Target Group, ALB, ASG
# =============================================================================
set -euo pipefail

: "${REGION:=eu-west-1}"
: "${PROJECT:=ec2-lab}"
: "${ACCOUNT_ID:=$(aws sts get-caller-identity --query Account --output text)}"

# Cargar IDs creados en scripts anteriores
# shellcheck disable=SC1090
[[ -f ~/.ec2-lab-env ]] && source ~/.ec2-lab-env

: "${VPC_ID:?Ejecuta primero 02-networking.sh}"
: "${SUBNET_PUB_A:?}" : "${SUBNET_PUB_B:?}" : "${SUBNET_PUB_C:?}"
: "${SUBNET_APP_A:?}"  : "${SUBNET_APP_B:?}"  : "${SUBNET_APP_C:?}"

GREEN='\033[0;32m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }

# -----------------------------------------------------------------------------
info "1/5 — Security Groups..."
# -----------------------------------------------------------------------------
SG_ALB=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-sg-alb-ext" \
  --description "ALB Externo — HTTP/HTTPS desde Internet" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT}-sg-alb-ext},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_ALB" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0 --region "$REGION"
echo "SG_ALB=$SG_ALB" >> ~/.ec2-lab-env

SG_EC2=$(aws ec2 create-security-group \
  --group-name "${PROJECT}-sg-ec2-app" \
  --description "EC2 App tier — solo desde ALB SG (puerto 8080)" \
  --vpc-id "$VPC_ID" \
  --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${PROJECT}-sg-ec2-app},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$SG_EC2" \
  --protocol tcp --port 8080 --source-group "$SG_ALB" --region "$REGION"
echo "SG_EC2=$SG_EC2" >> ~/.ec2-lab-env
success "SGs creados: ALB=$SG_ALB, EC2=$SG_EC2"

# -----------------------------------------------------------------------------
info "2/5 — Launch Template (IMDSv2, gp3, user-data)..."
# -----------------------------------------------------------------------------
# Obtener la AMI más reciente de Amazon Linux 2023
AMI_ID=$(aws ssm get-parameter \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --region "$REGION" --query Parameter.Value --output text)

USER_DATA=$(base64 -w0 << 'USERDATA'
#!/bin/bash
set -e
yum update -y
yum install -y python3 amazon-cloudwatch-agent

# Copiar app desde S3 si está disponible, o usar versión inline
if ! aws s3 cp "s3://$(aws sts get-caller-identity --query Account --output text | sed 's/.*//ec2-lab-assets-&/app/app.py" /opt/app.py 2>/dev/null; then
cat > /opt/app.py << 'PYAPP'
from http.server import HTTPServer, BaseHTTPRequestHandler
import socket, json, subprocess

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(b'{"status":"healthy"}')
        elif self.path == '/':
            token = subprocess.getoutput('curl -sf -X PUT http://169.254.169.254/latest/api/token -H "X-aws-ec2-metadata-token-ttl-seconds: 21600"')
            az = subprocess.getoutput(f'curl -sf -H "X-aws-ec2-metadata-token: {token}" http://169.254.169.254/latest/meta-data/placement/availability-zone')
            self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers()
            self.wfile.write(json.dumps({"host": socket.gethostname(), "az": az, "version": "v1.0"}).encode())
        else:
            self.send_response(404); self.end_headers()
    def log_message(self,*a): pass
HTTPServer(('0.0.0.0', 8080), H).serve_forever()
PYAPP
fi

cat > /etc/systemd/system/webapp.service << 'SVC'
[Unit]
Description=EC2 Lab WebApp
After=network.target
[Service]
ExecStart=/usr/bin/python3 /opt/app.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable webapp
systemctl start webapp
USERDATA
)

LT_ID=$(aws ec2 create-launch-template \
  --launch-template-name "${PROJECT}-lt-web" \
  --version-description "v1.0 — web tier, puerto 8080" \
  --launch-template-data "{
    \"ImageId\": \"${AMI_ID}\",
    \"InstanceType\": \"t3.micro\",
    \"KeyName\": \"${PROJECT}-key\",
    \"IamInstanceProfile\": {\"Name\": \"${PROJECT}-instance-profile\"},
    \"SecurityGroupIds\": [\"${SG_EC2}\"],
    \"UserData\": \"${USER_DATA}\",
    \"MetadataOptions\": {
      \"HttpTokens\": \"required\",
      \"HttpPutResponseHopLimit\": 1,
      \"InstanceMetadataTags\": \"enabled\"
    },
    \"BlockDeviceMappings\": [{
      \"DeviceName\": \"/dev/xvda\",
      \"Ebs\": {
        \"VolumeSize\": 20,
        \"VolumeType\": \"gp3\",
        \"Iops\": 3000,
        \"Throughput\": 125,
        \"DeleteOnTermination\": true,
        \"Encrypted\": true
      }
    }],
    \"TagSpecifications\": [{
      \"ResourceType\": \"instance\",
      \"Tags\": [
        {\"Key\": \"Name\", \"Value\": \"${PROJECT}-web\"},
        {\"Key\": \"Project\", \"Value\": \"${PROJECT}\"}
      ]
    }]
  }" \
  --tag-specifications "ResourceType=launch-template,Tags=[{Key=Name,Value=${PROJECT}-lt-web},{Key=Project,Value=${PROJECT}}]" \
  --region "$REGION" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)
echo "LT_ID=$LT_ID" >> ~/.ec2-lab-env
success "Launch Template: $LT_ID (AMI: $AMI_ID)"

# -----------------------------------------------------------------------------
info "3/5 — Target Group (instance, puerto 8080, health /health)..."
# -----------------------------------------------------------------------------
TG_ARN=$(aws elbv2 create-target-group \
  --name "${PROJECT}-tg-web" \
  --protocol HTTP --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --matcher HttpCode=200 \
  --tags "Key=Project,Value=${PROJECT}" "Key=Name,Value=${PROJECT}-tg-web" \
  --region "$REGION" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "TG_ARN=$TG_ARN" >> ~/.ec2-lab-env
success "Target Group: $TG_ARN"

# -----------------------------------------------------------------------------
info "4/5 — ALB (internet-facing, 3 subnets públicas)..."
# -----------------------------------------------------------------------------
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "${PROJECT}-alb-ext" \
  --subnets "$SUBNET_PUB_A" "$SUBNET_PUB_B" "$SUBNET_PUB_C" \
  --security-groups "$SG_ALB" \
  --scheme internet-facing \
  --type application \
  --ip-address-type ipv4 \
  --tags "Key=Project,Value=${PROJECT}" "Key=Name,Value=${PROJECT}-alb-ext" \
  --region "$REGION" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)

ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" --region "$REGION" \
  --query 'LoadBalancers[0].DNSName' --output text)

LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=${TG_ARN}" \
  --tags "Key=Project,Value=${PROJECT}" \
  --region "$REGION" \
  --query 'Listeners[0].ListenerArn' --output text)

echo "ALB_ARN=$ALB_ARN"         >> ~/.ec2-lab-env
echo "ALB_DNS=$ALB_DNS"         >> ~/.ec2-lab-env
echo "LISTENER_HTTP=$LISTENER_ARN" >> ~/.ec2-lab-env
success "ALB: $ALB_DNS"

# -----------------------------------------------------------------------------
info "5/5 — Auto Scaling Group (min=2, max=6, desired=2, health=ELB)..."
# -----------------------------------------------------------------------------
aws autoscaling create-auto-scaling-group \
  --auto-scaling-group-name "${PROJECT}-asg-web" \
  --launch-template "LaunchTemplateId=${LT_ID},Version=\$Latest" \
  --min-size 2 --max-size 6 --desired-capacity 2 \
  --target-group-arns "$TG_ARN" \
  --health-check-type ELB \
  --health-check-grace-period 120 \
  --vpc-zone-identifier "${SUBNET_APP_A},${SUBNET_APP_B},${SUBNET_APP_C}" \
  --tags \
    "Key=Name,Value=${PROJECT}-web,PropagateAtLaunch=true" \
    "Key=Project,Value=${PROJECT},PropagateAtLaunch=true" \
  --region "$REGION"

success "ASG '${PROJECT}-asg-web' creado."

echo ""
success "=== Compute v1 completado ==="
echo "  ALB DNS : http://$ALB_DNS"
echo ""
echo "Espera ~2 min y ejecuta: ./04-validacion.sh"
