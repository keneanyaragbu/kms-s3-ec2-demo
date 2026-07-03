output "instance_public_ip" {
  value = aws_instance.app.public_ip
}

output "bucket_name" {
  value = aws_s3_bucket.config.id
}

output "kms_key_id" {
  value = aws_kms_key.app_key.key_id
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/kms-demo-key ubuntu@${aws_instance.app.public_ip}"
}

output "verify_command" {
  value = "After SSH: cat /var/log/kms-demo.log"
}
