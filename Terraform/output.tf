output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnets" {
  value = module.vpc.private_subnets
}

output "public_subnets" {
  value = module.vpc.public_subnets
}

output "eks_cluster_id" {
  value = module.eks.cluster_id
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "rds_endpoint" {
  value = module.rds.db_instance_address
}

output "vault_public_ip" {
  value = aws_instance.vault.public_ip
}

output "vault_private_ip" {
  value = aws_instance.vault.private_ip
}
output "kms_key_id" {
  value = aws_kms_key.vault_auto_unseal.key_id
}

output "kms_key_arn" {
  value = aws_kms_key.vault_auto_unseal.arn
}
