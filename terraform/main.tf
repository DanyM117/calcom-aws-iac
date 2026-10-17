terraform {
  required_version = ">= 1.5.0"
  backend "s3" {
    bucket         = "tu-bucket-tfstate-calcom"
    key            = "prod/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    use_lockfile   = true # Nativo en Terraform >= 1.10 (reemplaza DynamoDB)
  }
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Obtener la VPC por defecto de tu cuenta
data "aws_vpc" "default" {
  default = true
}

# Security Group con los puertos web y SSH
resource "aws_security_group" "calcom_sg" {
  name        = "calcom-security-group"
  description = "Reglas de entrada para Cal.com (HTTP, HTTPS, SSH)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "calcom-sg"
  }
}

# AMI de Ubuntu 24.04 LTS más reciente
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Instancia EC2
resource "aws_instance" "calcom_server" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  vpc_security_group_ids      = [aws_security_group.calcom_sg.id]
  associate_public_ip_address = true

  root_block_device {
    volume_size = 30 # Mínimo 30 GB para imágenes Docker y builds de Prisma
    volume_type = "gp3"
  }

  # Inyecta el script de instalación automática
  user_data = file("${path.module}/templates/user_data.sh")

  tags = {
    Name = "calcom-production"
  }
}
