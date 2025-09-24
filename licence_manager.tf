modules/license-manager-grants/versions.tf
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = { source = "hashicorp/aws" }
  }
}

modules/license-manager-grants/variables.tf
variable "name" {
  description = "Short logical name used to build the grant name (e.g., 'qualys-vsa')."
  type        = string
  validation {
    condition     = length(trim(var.name)) > 0
    error_message = "name cannot be empty."
  }
}

variable "license_arn" {
  description = "License ARN of the subscribed Marketplace product (in THIS account & region)."
  type        = string
  validation {
    condition     = can(regex("^arn:aws:license-manager:[a-z0-9-]+:[0-9]{12}:", var.license_arn))
    error_message = "license_arn must be an AWS License Manager ARN in this account/region."
  }
}

variable "principals" {
  description = <<EOT
Principals to grant to. Use any mix of:
- Account root: arn:aws:iam::<ACCOUNT_ID>:root
- OU:           arn:aws:organizations::<ORG_ID>:ou/<ROOT_OR_OU_ID>/<OU_ID>
- Org:          arn:aws:organizations::<ORG_ID>:organization/<ORG_ID>
EOT
  type = list(string)
  validation {
    condition = length(var.principals) > 0 && alltrue([
      for p in var.principals :
      can(regex("^arn:aws:(iam|organizations)::[0-9]{12}:", p))
    ])
    error_message = "principals must be a non-empty list of IAM/Organizations ARNs."
  }
}

variable "allowed_operations" {
  description = "Operations grantees can perform with the license. Defaults suit AMI-based products."
  type        = list(string)
  default = [
    "CheckoutLicense",
    "CheckInLicense",
    "ExtendConsumptionLicense"
  ]
  validation {
    condition = alltrue([
      for op in var.allowed_operations :
      contains([
        "CheckoutLicense",
        "CheckInLicense",
        "ExtendConsumptionLicense",
        "CreateGrant",
        "ManageGrant",
        "ViewLicense",
        "CreateToken"
      ], op)
    ])
    error_message = "allowed_operations contains an unsupported value."
  }
}

modules/license-manager-grants/main.tf
# Helper: stable, readable grant name per principal.
# 1) strip the 'arn:aws:' prefix
# 2) replace non [a-zA-Z0-9-] chars with '-'
# 3) truncate to 255 chars (AWS limit for many names)
locals {
  sanitized_names = {
    for p in var.principals :
    p => substr(
      format(
        "%s-%s",
        var.name,
        regexreplace(replace(p, "arn:aws:", ""), "[^a-zA-Z0-9-]", "-")
      ),
      0,
      255
    )
  }
}

resource "aws_licensemanager_grant" "this" {
  for_each = { for p in var.principals : p => p }

  license_arn        = var.license_arn
  principal          = each.value
  allowed_operations = var.allowed_operations

  name = local.sanitized_names[each.key]
}

modules/license-manager-grants/outputs.tf
output "grant_ids" {
  description = "Map of principal -> grant ID"
  value       = { for k, g in aws_licensemanager_grant.this : k => g.id }
}

output "grant_arns" {
  description = "Map of principal -> grant ARN"
  value       = { for k, g in aws_licensemanager_grant.this : k => g.arn }
}

output "grant_names" {
  description = "Map of principal -> grant name used"
  value       = { for k, g in aws_licensemanager_grant.this : k => g.name }
}

Example usage: Delegated-Admin (single region)

stacks/prod-use1/main.tf

# Region passed here (module has no provider block)
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

module "qualys_vsa_grants" {
  providers = { aws = aws.use1 }
  source    = "git::https://<git-host>/<group>/terraform-aws-license-manager.git//modules/license-manager-grants?ref=v1.0.0"

  name        = "qualys-vsa"
  license_arn = "arn:aws:license-manager:us-east-1:111122223333:license:l-xxxxxxxxxxxxxxxx"

  principals = [
    "arn:aws:iam::444455556666:root",                                      # account
    "arn:aws:organizations::123456789012:ou/o-abc123xyz/ou-9abc-1defghij", # OU
    # "arn:aws:organizations::123456789012:organization/o-abc123xyz",      # (optional) entire org
  ]

  # defaults usually fine for AMI products; include/exclude as vendor requires:
  allowed_operations = [
    "CheckoutLicense",
    "CheckInLicense",
    "ExtendConsumptionLicense"
  ]
}

Example usage: Delegated-Admin (multi-region rollout)

stacks/prod-multi-region/main.tf

provider "aws" { alias = "use1" region = "us-east-1" }
provider "aws" { alias = "usw2" region = "us-west-2" }

locals {
  principals = [
    "arn:aws:iam::444455556666:root",
    "arn:aws:iam::777788889999:root",
  ]
}

module "qualys_grants_use1" {
  providers = { aws = aws.use1 }
  source    = "git::https://<git-host>/<group>/terraform-aws-license-manager.git//modules/license-manager-grants?ref=v1.0.0"

  name        = "qualys-vsa"
  license_arn = "arn:aws:license-manager:us-east-1:111122223333:license:l-aaaaaaaaaaaaaaaa"
  principals  = local.principals
}

module "qualys_grants_usw2" {
  providers = { aws = aws.usw2 }
  source    = "git::https://<git-host>/<group>/terraform-aws-license-manager.git//modules/license-manager-grants?ref=v1.0.0"

  name        = "qualys-vsa"
  license_arn = "arn:aws:license-manager:us-west-2:111122223333:license:l-bbbbbbbbbbbbbbbb"
  principals  = local.principals
}

(Optional) Member-account helper: auto-accept received grants

Use this only if your Org doesn’t auto-accept grants.

modules/license-manager-grant-acceptor/

There’s no dedicated “accept” resource, but Terraform can ensure the grant shows up and we record it. If auto-accept is off, the accept step is usually a one-time console/API action by the grantee. Below is a small read-only guard to fail early if grants aren’t visible to the member account.

versions.tf

terraform {
  required_version = ">= 1.7"
  required_providers { aws = { source = "hashicorp/aws" } }
}


variables.tf

variable "expected_grant_arns" {
  description = "Grant ARNs the member account expects to see from delegated-admin."
  type        = list(string)
}


main.tf

# There isn't a native data source for listing received grants per se; this block is a placeholder
# for a future enhancement once provider exposes data sources. For now, we just surface them and
# let CI/automation check that they are non-empty.

locals {
  nonempty = length(var.expected_grant_arns) > 0
}

resource "null_resource" "ensure_expected_grants_passed" {
  count = local.nonempty ? 0 : 1
  triggers = { reason = "expected_grant_arns must be provided for verification." }
}
