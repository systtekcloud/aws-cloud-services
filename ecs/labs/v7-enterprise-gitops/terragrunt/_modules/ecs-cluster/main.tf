# ── Módulo: ECS Cluster — ShopAPI ─────────────────────────────────────────────
# Crea el cluster ECS con Capacity Providers FARGATE y FARGATE_SPOT.
# Container Insights se activa/desactiva según el entorno para controlar costes.

resource "aws_ecs_cluster" "main" {
  name = "shopapi-cluster-${var.environment}"

  setting {
    name  = "containerInsights"
    value = var.container_insights ? "enabled" : "disabled"
  }

  tags = {
    Name = "shopapi-cluster-${var.environment}"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = var.capacity_providers

  # Estrategia por defecto: FARGATE como base garantizada
  # Los servicios pueden sobreescribir esta estrategia con la suya propia
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    base              = 1
    weight            = 1
  }
}
