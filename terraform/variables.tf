variable "aws_region" {
  description = "Región de AWS para el despliegue"
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Tipo de instancia EC2 (mínimo t3.medium para Cal.com)"
  type        = string
  default     = "t3a.medium"
}

variable "domain_name" {
  description = "Dominio o comodín para Nginx (o _ si solo usas IP)"
  type        = string
  default     = "_"
}