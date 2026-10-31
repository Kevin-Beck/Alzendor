# Alzendor's server for iterbotgames.com/alzendor: one small ARM instance in
# the default VPC, reachable on 443 only from CloudFront (and on 80 for
# certificate challenges), with an Elastic IP and a DNS name for CloudFront to
# use as its origin, and a private bucket for deploy.sh's releases. There's no
# SSH: deploy.sh uses SSM. The CloudFront route itself is added by
# cloudfront.sh, since the distribution isn't managed by Terraform.
#
# State is local (terraform.tfstate here, not in git): keep this machine's copy.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
  }
}

variable "aws_profile" {
  default = "admin-dev"
}

variable "domain" {
  default = "iterbotgames.com"
}

variable "origin_name" {
  description = "The origin's DNS name under the domain: CloudFront connects to it."
  default     = "alzendor-origin"
}

variable "instance_type" {
  default = "t4g.micro"
}

provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile
  default_tags {
    tags = { project = "alzendor" }
  }
}

data "aws_route53_zone" "site" {
  name = var.domain
}

data "aws_vpc" "default" {
  default = true
}

data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alzendor" {
  name        = "alzendor"
  description = "Alzendor: HTTPS from CloudFront only, HTTP for certificates"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "HTTPS from CloudFront"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  }

  ingress {
    description = "HTTP: certificate challenges and redirects"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# SSM instead of SSH: deploy.sh sends commands through it.
resource "aws_iam_role" "alzendor" {
  name = "alzendor-server"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.alzendor.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "alzendor" {
  name = "alzendor-server"
  role = aws_iam_role.alzendor.name
}

resource "aws_instance" "alzendor" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  vpc_security_group_ids = [aws_security_group.alzendor.id]
  iam_instance_profile   = aws_iam_instance_profile.alzendor.name
  user_data              = file("${path.module}/user-data.sh")

  root_block_device {
    volume_type = "gp3"
    volume_size = 12
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = { Name = "alzendor" }

  # A newer Ubuntu image (or an edited first-boot script) mustn't replace the
  # server and its Redis data.
  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "alzendor" {
  instance = aws_instance.alzendor.id
  domain   = "vpc"
}

resource "aws_route53_record" "origin" {
  zone_id = data.aws_route53_zone.site.zone_id
  name    = "${var.origin_name}.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.alzendor.public_ip]
}

# Releases: deploy.sh uploads the code here and hands the server a short-lived link.
resource "aws_s3_bucket" "releases" {
  bucket_prefix = "alzendor-releases-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "releases" {
  bucket                  = aws_s3_bucket.releases.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "releases" {
  bucket = aws_s3_bucket.releases.id
  rule {
    id     = "old-releases"
    status = "Enabled"
    filter {}
    expiration {
      days = 30
    }
  }
}

output "instance_id" {
  value = aws_instance.alzendor.id
}

output "origin_domain" {
  value = aws_route53_record.origin.fqdn
}

output "public_ip" {
  value = aws_eip.alzendor.public_ip
}

output "bucket" {
  value = aws_s3_bucket.releases.bucket
}
