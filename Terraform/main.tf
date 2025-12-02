/* ---------------------------
   VPC module (required by EKS)
   --------------------------- */
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = slice(data.aws_availability_zones.available.names, 0, 3)
  private_subnets = var.private_subnets
  public_subnets  = var.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  tags = {
    Project = "codeblaze"
  }
}

data "aws_availability_zones" "available" {}

/* ---------------------------
   EKS (Fargate) cluster
   --------------------------- */
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  enable_irsa = true

  # Fargate profile: pods in namespace "app" will be scheduled on Fargate
  fargate_profiles = {
    app = {
      name = "fp-app"
      selectors = [
        {
          namespace = "app"
        }
      ]
    }
  }

  tags = {
    Environment = "codeblaze"
  }
}

/* ---------------------------
   Security Group: RDS
   Allow inbound from private subnets CIDR(s) (Fargate pod ENIs are in private subnets)
   --------------------------- */
resource "aws_security_group" "rds_sg" {
  name        = "${var.cluster_name}-rds-sg"
  description = "RDS SG - allow Postgres from cluster private subnets"
  vpc_id      = module.vpc.vpc_id

ingress {
  description = "postgres access from VPC"
  from_port   = 5432
  to_port     = 5432
  protocol    = "tcp"
  cidr_blocks = [module.vpc.vpc_cidr_block]
}

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-rds-sg" }
}

/* ---------------------------
   RDS PostgreSQL (minimal)
   Uses terraform-aws-modules/rds/aws v6.x inputs
   --------------------------- */
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  identifier = "${var.cluster_name}-db"

  engine               = "postgres"
  engine_version       = "15"
  family               = "postgres15"
  major_engine_version = "15"

  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = "appdb"
  username = var.db_username
  password = var.db_password

  subnet_ids             = module.vpc.private_subnets
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  create_db_subnet_group = true
  create_db_parameter_group = false
  # 👆 forces the module not to create its own SGs or attach defaults

  publicly_accessible = false
  skip_final_snapshot = true

  tags = {
    Name = "${var.cluster_name}-rds"
  }
}


/* ---------------------------
   KMS key for Vault auto-unseal
   --------------------------- */
resource "aws_key_pair" "vault_key" {
  key_name   = "vault_key"
  public_key = file("${path.module}/id_rsa.pub")
}


/* ---------------------------
   IAM Role / Instance Profile for Vault EC2
   - allow EC2 to assume role
   - attach inline policy allowing use of the KMS key
   --------------------------- */
resource "aws_iam_role" "vault_ec2_role" {
  name = "${var.cluster_name}-vault-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "vault_kms_policy" {
  name = "${var.cluster_name}-vault-kms-policy"
  role = aws_iam_role.vault_ec2_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey",
          "kms:ListKeys",
          "kms:ListAliases"
        ]
        Resource = aws_kms_key.vault_auto_unseal.arn
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_kms_key" "vault_auto_unseal" {
  description = "KMS key for Vault auto-unseal"
}


resource "aws_iam_instance_profile" "vault_profile" {
  name = "${var.cluster_name}-vault-instance-profile"
  role = aws_iam_role.vault_ec2_role.name
}

/* ---------------------------
   Security Group: Vault EC2
   - allow Vault port 8200 from cluster private subnets (EKS pods + admin)
   - allow SSH from your IP (variable var.admin_cidr)
   --------------------------- */
resource "aws_security_group" "vault_sg" {
  name        = "${var.cluster_name}-vault-sg"
  description = "Vault server security group"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "Vault HTTP API"
    from_port   = 8200
    to_port     = 8200
    protocol    = "tcp"
    cidr_blocks = var.vault_allowed_cidrs != [] ? var.vault_allowed_cidrs : module.vpc.private_subnets
  }

  ingress {
    description = "SSH for admin"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.admin_cidr != "" ? [var.admin_cidr] : ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.cluster_name}-vault-sg" }
}

/* ---------------------------
   Vault EC2 instance (minimal)
   - put a small user_data script at vault_userdata.sh path to install + configure Vault
   --------------------------- */
resource "aws_instance" "vault" {
  ami                    = var.ami_for_vault
  instance_type          = var.vault_instance_type
  subnet_id              = element(module.vpc.public_subnets, 0)
  vpc_security_group_ids = [aws_security_group.vault_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.vault_profile.name

  key_name = aws_key_pair.vault_key.key_name

  user_data = fileexists("${path.module}/vault_userdata.sh") ? file("${path.module}/vault_userdata.sh") : ""

  associate_public_ip_address = true

  tags = {
    Name = "${var.cluster_name}-vault"
  }
}

