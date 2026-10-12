output "ec2_public_ip" {
  description = "Dirección IP pública asignada a la instancia"
  value       = aws_instance.calcom_server.public_ip
}

output "calcom_web_url" {
  description = "URL para acceder a Cal.com"
  value       = "http://${aws_instance.calcom_server.public_ip}"
}
