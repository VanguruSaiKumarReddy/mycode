1) modules/license-manager-grants/versions.tf
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

2) modules/license-manager-grants/variables.tf
variable "name" {
  description = "Short name used to build grant_name (e.g., qualys-vsa)"
  type        = string
}

variable "license_arn" {
  description = "License ARN of the subscribed Marketplace product in this account/region"
  type        = string
}

variable "principals" {
  description = <<EOT
List of principals to grant to:
- Account root: arn:aws:iam::<ACCOUNT_ID>:root
- OU:           arn:aws:organizations::<ORG_ID>:ou/<ROOT_OR_OU_ID>/<OU_ID>
- Org:          arn:aws:organizations::<ORG_ID>:organization/<ORG_ID>
EOT
  type = list(string)
}

variable "allowed_operations" {
  description = "Operations grantees can perform (typical for AMI-based Marketplace)"
  type        = list(string)
  default = [
    "CheckoutLicense",
    "CheckInLicense",
    "ExtendConsumptionLicense"
  ]
}

variable "tags" {
  description = "Tags to apply to grants"
  type        = map(string)
  default     = {}
}

3) modules/license-manager-grants/main.tf
# One grant per principal
resource "aws_licensemanager_grant" "this" {
  for_each = { for p in var.principals : p => p }

  license_arn        = var.license_arn
  principal          = each.value
  allowed_operations = var.allowed_operations

  # Build a stable, readable name (no locals needed)
  grant_name = format(
    "%s-%s",
    var.name,
    replace(replace(replace(each.value, "arn:aws:", ""), ":", "-"), "/", "-")
  )

  tags = var.tags
}

4) modules/license-manager-grants/outputs.tf
output "grant_arns" {
  description = "Map principal -> grant ARN"
  value       = { for k, g in aws_licensemanager_grant.this : k => g.arn }
}

output "grant_ids" {
  description = "Map principal -> grant ID"
  value       = { for k, g in aws_licensemanager_grant.this : k => g.id }
}

How to use at account level (delegated-admin)

Region comes from the provider you set in the root stack.

provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

module "qualys_vsa_grants" {
  providers = { aws = aws.use1 }
  source    = "git::https://<git-host>/<group>/terraform-aws-license-manager.git//modules/license-manager-grants?ref=v0.1.0"

  name        = "qualys-vsa"
  license_arn = "arn:aws:license-manager:us-east-1:111122223333:license:l-xxxxxxxxxxxxxxxx" # from LM after subscribing

  principals = [
    "arn:aws:iam::444455556666:root",
    "arn:aws:iam::777788889999:root",
    # or an OU / whole Org:
    # "arn:aws:organizations::123456789012:ou/o-abc123xyz/ou-9abc-1defghij",
    # "arn:aws:organizations::123456789012:organization/o-abc123xyz",
  ]

  # (optional) adjust if your vendor needs different ops
  allowed_operations = [
    "CheckoutLicense",
    "CheckInLicense",
    "ExtendConsumptionLicense"
  ]

  tags = {
    tfc-created-by               = "Platform-Automation"
    tfc-technical-supported-by   = "ITSM-AWS-Cloud-Platform-Engineering@truist.com"
    tfc-business-application-id  = "APP-QUALYS"
    tfc-business-cost-center     = "CC-SECOPS"
  }
}

Multi-region rollout (if you subscribed in more than one)
provider "aws" { alias = "use1" region = "us-east-1" }
provider "aws" { alias = "usw2" region = "us-west-2" }

module "qualys_grants_use1" {
  providers = { aws = aws.use1 }
  source    = "git::https://<git>/<group>/terraform-aws-license-manager.git//modules/license-manager-grants?ref=v0.1.0"
  name        = "qualys-vsa"
  license_arn = "<license-arn-in-us-east-1>"
  principals  = var.principals
  tags        = var.tags
}

module "qualys_grants_usw2" {
  providers = { aws = aws.usw2 }
  source    = "git::https://<git>/<group>/terraform-aws-license-manager.git//modules/license-manager-grants?ref=v0.1.0"
  name        = "qualys-vsa"
  license_arn = "<license-arn-in-us-west-2>"
  principals  = var.principals
  tags        = var.tags
}
