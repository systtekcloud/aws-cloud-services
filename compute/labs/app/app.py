"""
EC2 Lab — App de demostración multi-tier
Reutilizada en todas las versiones del lab (v1-v5)

Endpoints:
  GET /         → info de instancia (host, AZ, versión, tier)
  GET /health   → health check para ALB/ASG (siempre 200)
  GET /db-check → comprueba conectividad Aurora (v2+)
  GET /metrics  → métricas básicas de la app
"""

import json
import os
import socket
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

START_TIME = time.time()
REQUEST_COUNT = 0
VERSION = os.environ.get("APP_VERSION", "v1.0")
TIER = os.environ.get("APP_TIER", "web")
PORT = int(os.environ.get("PORT", 8080))
REGION = os.environ.get("AWS_DEFAULT_REGION", "eu-west-1")


def _imdsv2_get(path: str) -> str:
    """Consulta IMDSv2 de forma segura (token TTL=21600s)."""
    try:
        token = subprocess.getoutput(
            'curl -sf -X PUT "http://169.254.169.254/latest/api/token" '
            '-H "X-aws-ec2-metadata-token-ttl-seconds: 21600"'
        )
        return subprocess.getoutput(
            f'curl -sf -H "X-aws-ec2-metadata-token: {token}" '
            f"http://169.254.169.254/latest/meta-data/{path}"
        )
    except Exception:
        return "unknown"


def _get_secret(secret_name: str) -> dict:
    """Recupera un secreto de Secrets Manager (requiere IAM role)."""
    import boto3

    client = boto3.client("secretsmanager", region_name=REGION)
    return json.loads(client.get_secret_value(SecretId=secret_name)["SecretString"])


class Handler(BaseHTTPRequestHandler):
    def _send_json(self, code: int, data: dict):
        body = json.dumps(data, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        global REQUEST_COUNT
        REQUEST_COUNT += 1

        if self.path == "/health":
            self._send_json(200, {"status": "healthy"})

        elif self.path == "/":
            az = _imdsv2_get("placement/availability-zone")
            instance_id = _imdsv2_get("instance-id")
            instance_type = _imdsv2_get("instance-type")
            self._send_json(200, {
                "host": socket.gethostname(),
                "instance_id": instance_id,
                "instance_type": instance_type,
                "az": az,
                "version": VERSION,
                "tier": TIER,
            })

        elif self.path == "/db-check":
            aurora_host = os.environ.get("AURORA_WRITER", "")
            if not aurora_host:
                self._send_json(200, {"db": "not_configured", "note": "Set AURORA_WRITER env var"})
                return
            try:
                import pymysql
                creds = _get_secret("ec2-lab/aurora/master")
                conn = pymysql.connect(
                    host=aurora_host,
                    user=creds["username"],
                    password=creds["password"],
                    database=creds.get("dbname", "appdb"),
                    connect_timeout=5,
                )
                with conn.cursor() as cur:
                    cur.execute("SELECT VERSION()")
                    version = cur.fetchone()[0]
                conn.close()
                self._send_json(200, {"db": "connected", "aurora_version": version})
            except ImportError:
                self._send_json(503, {"db": "error", "detail": "pymysql not installed"})
            except Exception as e:
                self._send_json(503, {"db": "error", "detail": str(e)})

        elif self.path == "/metrics":
            uptime = int(time.time() - START_TIME)
            self._send_json(200, {
                "uptime_seconds": uptime,
                "requests_total": REQUEST_COUNT,
                "version": VERSION,
                "tier": TIER,
            })

        else:
            self._send_json(404, {"error": "not found", "path": self.path})

    def log_message(self, fmt, *args):
        # Formatear logs en una línea para CloudWatch
        print(f"[{self.log_date_time_string()}] {self.address_string()} {fmt % args}")


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), Handler)
    print(f"EC2 Lab App {VERSION} ({TIER} tier) escuchando en :{PORT}")
    server.serve_forever()
