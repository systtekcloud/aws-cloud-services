# =============================================================================
# ec2.tf — Consumer EC2 (VPC-A) + Provider EC2 (VPC-B) + IAM para SSM
# =============================================================================

# ---------------------------------------------------------------------------
# IAM Role + Instance Profile para SSM Session Manager (consumer EC2)
# AmazonSSMManagedInstanceCore permite:
#   - ssm:UpdateInstanceInformation (heartbeat del agente)
#   - ssmmessages:* (canal de sesión)
#   - ec2messages:* (comandos Run Command)
# ---------------------------------------------------------------------------
resource "aws_iam_role" "consumer_ssm" {
  name        = "${var.prefix}-consumer-ssm-role"
  description = "Permite a la EC2 consumer registrarse en SSM Session Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "consumer_ssm" {
  role       = aws_iam_role.consumer_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "consumer_ssm" {
  name = "${var.prefix}-consumer-ssm-profile"
  role = aws_iam_role.consumer_ssm.name
}

# ---------------------------------------------------------------------------
# Consumer EC2 — VPC-A (subnet pública)
# Esta instancia ejecutará el curl al Interface Endpoint para probar PrivateLink
# AL2023 tiene SSM Agent preinstalado — no necesitamos SSH
# ---------------------------------------------------------------------------
resource "aws_instance" "consumer" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.a.id
  vpc_security_group_ids = [aws_security_group.consumer.id]
  iam_instance_profile   = aws_iam_instance_profile.consumer_ssm.name

  # IP pública necesaria para que el SSM agent contacte los endpoints de AWS
  # (sin esta IP necesitaríamos VPC Interface Endpoints para ssm/ssmmessages/ec2messages)
  associate_public_ip_address = true

  # IMDSv2 obligatorio — buena práctica aunque sea un lab
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Configurar hostname descriptivo para identificar la instancia en los logs
    hostnamectl set-hostname consumer-vpc-a
    echo "127.0.0.1 consumer-vpc-a" >> /etc/hosts

    # Instalar herramientas de diagnóstico de red
    dnf install -y nc telnet bind-utils 2>/dev/null || true

    # Esperar a que el SSM agent esté listo (arranca en el boot)
    systemctl start amazon-ssm-agent
    systemctl enable amazon-ssm-agent
  EOF
  )

  tags = { Name = "${var.prefix}-consumer-ec2-vpc-a" }
}

# ---------------------------------------------------------------------------
# Provider EC2 — VPC-B (subnet privada)
# Esta instancia sirve un HTTP server en el puerto ${var.http_port}
# No tiene acceso a internet — es un "microservicio" interno accesible via PrivateLink
# ---------------------------------------------------------------------------
resource "aws_instance" "provider" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.b.id
  vpc_security_group_ids = [aws_security_group.provider.id]

  # Sin IP pública — el provider no necesita acceso externo
  # El acceso solo llega via NLB → PrivateLink desde VPC-A
  associate_public_ip_address = false

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    # Configurar hostname
    hostnamectl set-hostname provider-vpc-b
    echo "127.0.0.1 provider-vpc-b" >> /etc/hosts

    # Crear servidor HTTP Python que responde con info de la instancia
    # Esto demuestra que el tráfico realmente llega a VPC-B
    cat > /usr/local/bin/lab-server.py << 'PYTHON'
#!/usr/bin/env python3
import http.server
import socketserver
import socket
import json
from datetime import datetime, timezone

class LabHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        hostname = socket.gethostname()
        response = json.dumps({
            "status": "OK",
            "message": "Tráfico recibido via AWS PrivateLink",
            "server": hostname,
            "vpc": "VPC-B (Provider) — CIDR 10.0.0.0/16",
            "concept": "PrivateLink funciona con CIDRs solapados. VPC Peering no.",
            "path": self.path,
            "client_ip": self.client_address[0],
            "timestamp": datetime.now(timezone.utc).isoformat()
        }, indent=2, ensure_ascii=False)

        body = response.encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Log a stdout para que aparezca en journald
        print(f"[{datetime.now(timezone.utc).isoformat()}] {format % args}", flush=True)

PORT = ${var.http_port}
with socketserver.TCPServer(("", PORT), LabHandler) as httpd:
    print(f"Lab HTTP Server escuchando en puerto {PORT}", flush=True)
    httpd.serve_forever()
PYTHON

    chmod +x /usr/local/bin/lab-server.py

    # Crear servicio systemd para el servidor HTTP
    cat > /etc/systemd/system/lab-server.service << 'SERVICE'
[Unit]
Description=Lab HTTP Server — PrivateLink Demo (VPC-B provider)
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/lab-server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
SERVICE

    systemctl daemon-reload
    systemctl enable lab-server
    systemctl start lab-server
  EOF
  )

  tags = { Name = "${var.prefix}-provider-ec2-vpc-b" }
}
