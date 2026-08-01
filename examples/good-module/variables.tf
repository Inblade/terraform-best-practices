variable "bucket_name" {
  description = "Globally unique S3 bucket name. Must be DNS-compliant: 3-63 characters, lowercase letters, digits, hyphens and dots."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.bucket_name))
    error_message = "bucket_name must be 3-63 characters of lowercase alphanumerics, dots or hyphens, starting and ending with a letter or digit."
  }
}

variable "versioning_enabled" {
  description = "Whether object versioning is enabled. Setting this to false on an existing bucket suspends versioning; it does not delete existing versions."
  type        = bool
  default     = true
  nullable    = false
}

variable "kms_key_arn" {
  description = "ARN of a KMS key used for SSE-KMS. When null the bucket uses SSE-S3 (AES256). S3 Bucket Keys are enabled automatically for SSE-KMS."
  type        = string
  default     = null
}

variable "force_destroy" {
  description = "Allow Terraform to delete a non-empty bucket. Keep false outside ephemeral test environments."
  type        = bool
  default     = false
  nullable    = false
}

variable "lifecycle_rules" {
  description = "Lifecycle rules keyed by rule ID. Map keys become the S3 rule IDs, so they must be stable across applies."
  type = map(object({
    prefix                             = optional(string, "")
    transition_days                    = optional(number)
    storage_class                      = optional(string, "STANDARD_IA")
    expiration_days                    = optional(number)
    noncurrent_version_expiration_days = optional(number)
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([for r in values(var.lifecycle_rules) :
      contains(["STANDARD_IA", "ONEZONE_IA", "INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"], r.storage_class)
    ])
    error_message = "storage_class must be one of STANDARD_IA, ONEZONE_IA, INTELLIGENT_TIERING, GLACIER_IR, GLACIER, DEEP_ARCHIVE."
  }

  validation {
    condition = alltrue([for r in values(var.lifecycle_rules) :
      r.transition_days == null || r.expiration_days == null || r.expiration_days > r.transition_days
    ])
    error_message = "expiration_days must be greater than transition_days when both are set on the same rule."
  }
}

variable "tags" {
  description = "Tags applied to the bucket. The module's own Name and ManagedBy tags take precedence over conflicting keys."
  type        = map(string)
  default     = {}
  nullable    = false
}
