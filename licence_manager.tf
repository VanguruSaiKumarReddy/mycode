1) modules/license-manager/versions.tf
terraform {
  required_version = ">= 1.7"
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

2) modules/license-manager/data.tf
# Identity + region guard (US four regions only)
data "aws_caller_identity" "current" {}

data "aws_region" "current" {
  lifecycle {
    postcondition {
      condition     = contains(["us-east-1", "us-east-2", "us-west-1", "us-west-2"], self.name)
      error_message = "Region should be one of the four US regions - us-east-1, us-east-2, us-west-1 or us-west-2!"
    }
  }
}

3) modules/license-manager/locals.tf
locals {
  # Org defaults + user-provided tags (match your pattern)
  tags_all = merge(
    {
      tfc-business-logical-usage-type = "Security"
      tfc-technical-supported-by      = "ITSM-AWS-Cloud-Platform-Engineering@truist.com"
      tfc-technical-created-by        = "Terraform"
    },
    var.tags_all,
    var.tags_all_services,
    var.tags_custom,
  )
}

4) modules/license-manager/variables.tf
variable "name" {
  description = "License configuration name (required when creating)"
  type        = string
  default     = null
}

variable "description" {
  description = "Optional description"
  type        = string
  default     = null
}

variable "create_license_configuration" {
  description = "If true, create a new license configuration; otherwise attach to existing_license_configuration_arn"
  type        = bool
  default     = true
}

variable "existing_license_configuration_arn" {
  description = "Existing license configuration ARN when create_license_configuration = false"
  type        = string
  default     = null
}

variable "license_count" {
  description = "Number of licenses available (null for unlimited when hard limit is false)"
  type        = number
  default     = null
}

variable "license_count_hard_limit" {
  description = "Whether to enforce a hard limit on license usage"
  type        = bool
  default     = false
}

variable "license_counting_type" {
  description = "Counting type: vCPU | Instance | Core | Socket"
  type        = string
  default     = "vCPU"
  validation {
    condition     = contains(["vCPU", "Instance", "Core", "Socket"], var.license_counting_type)
    error_message = "license_counting_type must be one of: vCPU, Instance, Core, Socket"
  }
}

variable "license_rules" {
  description = "List of License Manager rules (e.g., licenseAffinityToHost=host, allowedTenancy=EC2-Default, requireOnInstanceLaunch=true)"
  type        = list(string)
  default     = []
}

variable "associate_target_arns" {
  description = "List of resource ARNs (AMI/Instance/etc.) to associate to the license configuration"
  type        = list(string)
  default     = []
}

# Tag schema (mirrors your validation pattern)
variable "tags_all_services" {
  description = "Map of tags applied to all resources (service-scoped)"
  type        = map(string)
  default     = {}
}

variable "tags_all" {
  description = "Map of tags applied to all resources (org baseline). Must include mandatory keys."
  type        = map(string)
  default     = {}

  validation {
    condition     = contains(keys(var.tags_all), "tfc-created-by")
    error_message = "Tags variable does not have tfc-created-by mandatory tag key"
  }
  validation {
    condition     = contains(keys(var.tags_all), "tfc-technical-supported-by")
    error_message = "Tags variable does not have tfc-technical-supported-by mandatory tag key"
  }
  validation {
    condition     = contains(keys(var.tags_all), "tfc-business-application-id")
    error_message = "Tags variable does not have tfc-business-application-id mandatory tag key"
  }
  validation {
    condition     = contains(keys(var.tags_all), "tfc-business-cost-center")
    error_message = "Tags variable does not have tfc-business-cost-center mandatory tag key"
  }
}

variable "tags_custom" {
  description = "Optional map of extra tags"
  type        = map(string)
  default     = {}
}

5) modules/license-manager/main.tf
# Create or reference the License Configuration
resource "aws_licensemanager_license_configuration" "this" {
  count = var.create_license_configuration ? 1 : 0

  name                      = var.name
  description               = var.description
  license_count             = var.license_count
  license_count_hard_limit  = var.license_count_hard_limit
  license_counting_type     = var.license_counting_type
  license_rules             = var.license_rules
  tags                      = local.tags_all
}

# Resolve ARN to associate (created vs existing)
locals {
  target_license_configuration_arn = var.create_license_configuration
    ? aws_licensemanager_license_configuration.this[0].arn
    : var.existing_license_configuration_arn
}

# Guard: when attach-only, require an ARN
locals {
  _attach_only_guard = var.create_license_configuration ? true : (
    var.existing_license_configuration_arn != null && length(var.existing_license_configuration_arn) > 20
  )
}

resource "null_resource" "attach_only_validation" {
  count = local._attach_only_guard ? 0 : 1
  triggers = {
    reason = "existing_license_configuration_arn must be provided when create_license_configuration=false"
  }
}

# Optional: associate configuration to resource ARNs
resource "aws_licensemanager_association" "this" {
  for_each = toset(var.associate_target_arns)

  license_configuration_arn = local.target_license_configuration_arn
  resource_arn              = each.value
}

6) modules/license-manager/outputs.tf
output "license_configuration_id" {
  description = "License configuration ID (null when attach-only)"
  value       = try(aws_licensemanager_license_configuration.this[0].id, null)
}

output "license_configuration_arn" {
  description = "License configuration ARN (created or existing)"
  value       = local.target_license_configuration_arn
}

How to use at account level
Option A — Create a new License Configuration and (optionally) attach

stacks/prod-us-east-1/main.tf

# Aliased provider per-region (no provider block inside module)
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

module "license_manager_win_per_vcpu" {
  providers = { aws = aws.use1 }
  source    = "git::https://<your-git-host>/<group>/terraform-aws-license-manager.git//modules/license-manager?ref=v0.1.0"

  # Create + attach
  create_license_configuration = true
  name                         = "win-std-per-vcpu"
  description                  = "Windows Server Standard per-vCPU governance"
  license_counting_type        = "vCPU"
  license_count                = 1000
  license_count_hard_limit     = true
  license_rules = [
    "allowedTenancy=EC2-Default",
    "licenseAffinityToHost=none",
    "requireOnInstanceLaunch=true"
  ]

  # Attach to AMIs/instances in this account/region (optional)
  associate_target_arns = [
    # "arn:aws:ec2:us-east-1:111122223333:image/ami-0123456789abcdef0",
    # "arn:aws:ec2:us-east-1:111122223333:instance/i-0abc1234def567890",
  ]

  # Tag contract (matches your validations)
  tags_all = {
    tfc-created-by               = "Platform-Automation"
    tfc-technical-supported-by   = "ITSM-AWS-Cloud-Platform-Engineering@truist.com"
    tfc-business-application-id  = "APP-12345"
    tfc-business-cost-center     = "CC-67890"
  }

  tags_all_services = {
    "sti:base:created-by" = "Platform-Automation"
  }

  tags_custom = {
    Workload = "Windows"
  }
}

Option B — Attach-only in member accounts

Use this when the License Configuration is created centrally (e.g., delegated-admin). You only bind resources in each member account.

stacks/member-us-east-2/main.tf

provider "aws" {
  alias  = "use2"
  region = "us-east-2"
}

module "license_manager_attach_existing" {
  providers = { aws = aws.use2 }
  source    = "git::https://<your-git-host>/<group>/terraform-aws-license-manager.git//modules/license-manager?ref=v0.1.0"

  create_license_configuration       = false
  existing_license_configuration_arn = "arn:aws:license-manager:us-east-2:111122223333:license-configuration:lic-abc123xyz"

  associate_target_arns = [
    # Bind account-local AMIs/instances here
  ]

  tags_all = {
    tfc-created-by               = "Platform-Automation"
    tfc-technical-supported-by   = "ITSM-AWS-Cloud-Platform-Engineering@truist.com"
    tfc-business-application-id  = "APP-98765"
    tfc-business-cost-center     = "CC-11223"
  }
}
