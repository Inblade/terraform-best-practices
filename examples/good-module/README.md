# s3-bucket

A deliberately small, opinionated S3 bucket module. It exists as a worked example
for the guidance in [`../../docs/module-design.md`](../../docs/module-design.md),
not as a general-purpose replacement for the community S3 modules.

What it demonstrates:

- Modern AWS provider style: versioning, encryption, public access blocking and
  lifecycle rules are **separate resources**, not deprecated inline arguments on
  `aws_s3_bucket`.
- Two real `validation` blocks that reject bad input at plan time instead of
  letting the AWS API reject it 40 seconds into an apply.
- A narrow interface: seven inputs, four outputs, no feature flags that toggle
  whole architectures.
- `optional()` object attributes with defaults, so the `lifecycle_rules` map
  stays readable at the call site.
- No `provider` block. Provider configuration is the root module's job.

Deliberate omissions: bucket policies, replication, notifications, logging,
object ownership controls, Object Lock. Each of those is a separate resource the
caller can attach using the `id` output. Adding them here would double the
variable count and make the module harder to review than the resources it wraps.

## Usage

```hcl
module "artifacts" {
  source = "./examples/good-module"

  bucket_name = "acme-build-artifacts-euw1"
  kms_key_arn = aws_kms_key.artifacts.arn

  lifecycle_rules = {
    expire-old-builds = {
      prefix                             = "builds/"
      transition_days                    = 30
      storage_class                      = "GLACIER_IR"
      expiration_days                    = 365
      noncurrent_version_expiration_days = 30
    }

    expire-tmp = {
      prefix          = "tmp/"
      expiration_days = 7
    }
  }

  tags = {
    Environment = "prod"
    Owner       = "platform"
  }
}
```

Minimal call — SSE-S3 encryption, versioning on, no lifecycle rules:

```hcl
module "logs" {
  source      = "./examples/good-module"
  bucket_name = "acme-access-logs-euw1"
}
```

Attaching a policy from the caller, using the outputs rather than a module input:

```hcl
resource "aws_s3_bucket_policy" "artifacts" {
  bucket = module.artifacts.id
  policy = data.aws_iam_policy_document.artifacts.json
}

data "aws_iam_policy_document" "artifacts" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${module.artifacts.arn}/*"]

    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.ci.arn]
    }
  }
}
```

## Requirements

| Name      | Version  |
|-----------|----------|
| terraform | >= 1.9   |
| aws       | ~> 5.60  |

`>= 1.9` is required for the multiple `validation` blocks and `optional()`
attribute defaults used here. The module also works unchanged on OpenTofu 1.8+.

## Providers

| Name | Version |
|------|---------|
| aws  | ~> 5.60 |

The module declares `aws` in `required_providers` but does **not** configure it.
The root module supplies region, credentials and `default_tags`.

## Resources

| Name                                                | Type     |
|-----------------------------------------------------|----------|
| `aws_s3_bucket.this`                                | resource |
| `aws_s3_bucket_public_access_block.this`            | resource |
| `aws_s3_bucket_versioning.this`                     | resource |
| `aws_s3_bucket_server_side_encryption_configuration.this` | resource |
| `aws_s3_bucket_lifecycle_configuration.this`        | resource (conditional) |

`aws_s3_bucket_lifecycle_configuration` is created only when `lifecycle_rules`
is non-empty, so a bucket with no rules does not carry an empty configuration
resource that the provider would otherwise fight with.

## Inputs

| Name                 | Description | Type | Default | Required |
|----------------------|-------------|------|---------|:--------:|
| `bucket_name`        | Globally unique S3 bucket name. Must be DNS-compliant: 3-63 characters, lowercase letters, digits, hyphens and dots. | `string` | n/a | yes |
| `versioning_enabled` | Whether object versioning is enabled. Setting this to `false` on an existing bucket suspends versioning; it does not delete existing versions. | `bool` | `true` | no |
| `kms_key_arn`        | ARN of a KMS key used for SSE-KMS. When `null` the bucket uses SSE-S3 (AES256). S3 Bucket Keys are enabled automatically for SSE-KMS. | `string` | `null` | no |
| `force_destroy`      | Allow Terraform to delete a non-empty bucket. Keep `false` outside ephemeral test environments. | `bool` | `false` | no |
| `lifecycle_rules`    | Lifecycle rules keyed by rule ID. Map keys become the S3 rule IDs, so they must be stable across applies. | `map(object({ prefix = optional(string, ""), transition_days = optional(number), storage_class = optional(string, "STANDARD_IA"), expiration_days = optional(number), noncurrent_version_expiration_days = optional(number) }))` | `{}` | no |
| `tags`               | Tags applied to the bucket. The module's own `Name` and `ManagedBy` tags take precedence over conflicting keys. | `map(string)` | `{}` | no |

### Input validation

| Variable | Rule | Rejected example |
|----------|------|------------------|
| `bucket_name` | Matches `^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$` | `My_Bucket` (uppercase, underscore) |
| `lifecycle_rules` | `storage_class` is one of `STANDARD_IA`, `ONEZONE_IA`, `INTELLIGENT_TIERING`, `GLACIER_IR`, `GLACIER`, `DEEP_ARCHIVE` | `storage_class = "GLACIER_DEEP"` |
| `lifecycle_rules` | `expiration_days > transition_days` when both set | `transition_days = 90, expiration_days = 30` |

The `lifecycle_rules` map is keyed rather than a list on purpose. Rule IDs come
from the map keys, so removing a rule from the middle of the set does not shift
every rule after it — see the `count` versus `for_each` section in
[`../../docs/anti-patterns.md`](../../docs/anti-patterns.md).

## Outputs

| Name | Description | Sensitive |
|------|-------------|:---------:|
| `id` | Bucket name, which is also the Terraform resource ID. | no |
| `arn` | Bucket ARN. Use this when composing IAM policy statements. | no |
| `bucket_regional_domain_name` | Regional domain name. Prefer this over the global one for CloudFront origins and same-region clients. | no |
| `sse_algorithm` | Server-side encryption algorithm actually applied: `AES256` or `aws:kms`. | no |

Nothing here is sensitive: an S3 bucket module produces only identifiers. A
module that produced an access key or a generated password would mark those
outputs `sensitive = true`, and callers would still need to treat state as
secret — see [`../../docs/state-management.md`](../../docs/state-management.md).

## Notes and caveats

- **`versioning_enabled = false` on an existing bucket suspends, it does not
  disable.** Existing noncurrent versions stay and keep costing money. Pair it
  with a `noncurrent_version_expiration_days` rule if you want them gone.
- **`force_destroy = true` is a footgun in shared accounts.** It lets a
  `terraform destroy` delete every object with no further confirmation. Set it
  only in test roots that are torn down by CI.
- **Bucket names are globally unique across all AWS accounts.** The validation
  catches syntax, not collisions; an in-use name still fails at apply.
- **`depends_on` on the lifecycle configuration is intentional**, not cargo
  cult. Noncurrent-version rules are rejected by the API until the versioning
  configuration exists, and there is no attribute reference between the two
  resources to create that ordering implicitly.
- **This module does not set `default_tags`.** If the root module sets them, the
  bucket inherits them on top of `local.tags`, and the module's `Name`/`ManagedBy`
  keys will conflict-resolve in favour of the resource-level tags.
