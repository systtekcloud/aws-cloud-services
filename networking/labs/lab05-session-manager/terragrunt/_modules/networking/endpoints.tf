# _modules/networking/endpoints.tf
#
# Los 3 Interface Endpoints necesarios para SSM Session Manager.
# Sin los tres, SSM no funciona. Cada uno sirve para algo distinto:
#
#   ssm          → registro del agente + polling de comandos pendientes
#   ssmmessages  → canal WebSocket de Session Manager (shell interactivo)
#   ec2messages  → Run Command (comandos no interactivos via SSM)
#
# REQUISITO CRÍTICO: enable_dns_hostnames y enable_dns_support = true en la VPC.
# Sin ellos, los endpoints no generan registros DNS privados y SSM Agent
# no puede resolver los nombres de los servicios.
#
# En modo "internet" este fichero no crea nada (count = 0 en todos los recursos).

locals {
  # Los 3 servicios SSM necesarios — en este orden y sin excepción
  ssm_services = var.ssm_mode == "endpoints" ? [
    "com.amazonaws.${var.region}.ssm",
    "com.amazonaws.${var.region}.ssmmessages",
    "com.amazonaws.${var.region}.ec2messages",
  ] : []
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(local.ssm_services)

  vpc_id              = aws_vpc.this.id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true  # genera registros DNS privados — OBLIGATORIO para SSM

  tags = {
    Name = "lab05-endpoint-${replace(each.value, "com.amazonaws.${var.region}.", "")}-${var.environment}"
  }
}
