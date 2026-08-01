# Module Design

A module's interface is a contract. Once someone else consumes it, every
variable you accept and every output you expose is something you cannot change
without breaking them. Modules are cheap to write and expensive to own.

The single most useful design question: **what does the caller need to know to
use this, and what should it be able to forget?** A module that requires the
caller to understand every resource inside it has not abstracted anything.

---

## 1. Variable design

### Types, not strings

Terraform's type system is the only free validation you get. Use it.

```hcl
# Bad: everything is a string, nothing is checked, the shape is undocumented.
variable "config" {
  type    = string
  default = "{\"cpu\":512,\"memory\":1024}"
}

# Good: the type IS the documentation, and errors surface at plan time.
variable "task" {
  description = "ECS task sizing and container image."
  type = object({
    cpu    = number
    memory = number
    image  = string
    env    = optional(map(string), {})
  })
}
```

`optional()` with a default (Terraform 1.3+) is what makes object types usable
at scale — without it, every caller must supply every attribute, and adding one
attribute is a breaking change for everybody.

Avoid `any`. It disables type checking for the whole value and produces
error messages that point at the module internals rather than the caller's
mistake. The only defensible uses are genuinely opaque pass-through blobs, such
as a policy document rendered elsewhere.

### Validation blocks

Validation moves failure from "40 seconds into apply, with half the resources
created" to "immediately, with a message you wrote".

```hcl
# A good variable block.
variable "retention_days" {
  description = <<-EOT
    CloudWatch log retention in days. Must be a value the CloudWatch API
    accepts; arbitrary numbers are silently rounded up by AWS, which shows as
    permanent drift.
  EOT
  type     = number
  default  = 30
  nullable = false

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653],
      var.retention_days
    )
    error_message = "retention_days must be one of the values CloudWatch accepts (1, 3, 5, 7, 14, 30, 60, 90, ... 3653). Other values cause permanent drift."
  }
}
```

Note what makes the error message good: it says what is wrong, what the legal
values are, **and why the constraint exists**. An error message that just says
"invalid value" wastes the reader's next ten minutes.

For contrast, a bad variable block:

```hcl
# Bad: no description, no type constraint, meaningless default, no validation,
# and the name does not say what unit it is in.
variable "retention" {
  default = 0
}
```

`0` here is not a sane default — it is a sentinel that some code inside the
module presumably special-cases. Sentinel defaults are how modules acquire
undocumented behaviour.

Multiple `validation` blocks per variable are allowed and encouraged; each one
gets its own message, so keep them single-purpose:

```hcl
variable "vpc_cidr" {
  description = "CIDR block for the VPC. Must be a /16 to /20 from RFC1918 space."
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block, e.g. 10.40.0.0/16."
  }

  validation {
    condition     = tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr prefix must be between /16 and /20; smaller blocks cannot be subnetted across three AZs by this module."
  }
}
```

**Version note:** Terraform 1.9 relaxed validation conditions so they can refer
to *other* variables, data sources and locals, not just `var.self`. Before 1.9
you had to fake cross-variable checks with `check` blocks or `precondition`.
Terraform 1.9 also added `terraform.applying` for
apply-vs-plan-aware conditions. On older versions, use `lifecycle { precondition }`
on a resource, or a `check` block (1.5+).

### `nullable`, `sensitive`, and defaults

| Attribute | Use when | Watch out for |
|---|---|---|
| `nullable = false` | The module cannot handle `null` — most collections and bools | Default is `nullable = true`; a caller passing `null` gets the *default*, which surprises people |
| `sensitive = true` | The value is a secret | Only affects CLI output. It still lands in state in plaintext, and it makes every downstream expression sensitive, which can make plan output unreadable |
| `default` | A genuinely sane, safe-in-production value exists | No default is better than a wrong default. `default = ""` and `default = null` used as "unset" markers are a smell |
| `ephemeral = true` (1.10+) | A secret that must never touch state or plan files | Cannot be used where the value must persist; provider support varies |

Rule of thumb: **required variables should be the ones with no safe answer.**
Region, name and CIDR have no safe default. Encryption-on and
public-access-blocked do — and the safe default is the secure one.

### Do not toggle architectures with booleans

```hcl
# Bad. This module is now two modules pretending to be one.
variable "use_aurora" {
  type    = bool
  default = false
}

variable "enable_multi_region" {
  type    = bool
  default = false
}
```

Every such flag doubles the number of code paths, and the untested combination
is always the one production needs. Internally it produces `count = var.x ? 1 : 0`
on half the resources and conditional outputs full of `try()`.

Write `rds-instance` and `rds-aurora` as separate modules. They share a
networking module and a parameter-group module if that is genuinely common; they
do not share a variable.

The defensible boolean is one that toggles a **single optional resource** whose
absence changes nothing else — `create_dns_record`, `enable_access_logging`.

---

## 2. Output design

Outputs are how callers compose. Under-exposing forces callers to re-derive
values with data sources or string interpolation, which is worse than exposing
too much.

Export, for each significant resource: **id, arn, name**, plus anything needed
to build a policy, a DNS record, or a security-group rule.

```hcl
output "cluster_id" {
  description = "EKS cluster name/ID, for `aws eks update-kubeconfig`."
  value       = aws_eks_cluster.this.id
}

output "cluster_endpoint" {
  description = "HTTPS endpoint of the Kubernetes API server."
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 PEM of the cluster CA, for kubeconfig and provider config."
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider, for IRSA trust policies."
  value       = aws_iam_openid_connect_provider.this.arn
}

output "node_security_group_id" {
  description = "Security group attached to managed node groups. Callers attach ingress rules here rather than passing rules into this module."
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}
```

That last one is the important pattern: **expose the handle, let the caller
attach.** The alternative — a `var.additional_security_group_rules` input — is
how modules acquire twenty pass-through variables.

Rules:

- **Every output gets a `description`.** terraform-docs renders it; humans read it.
- **Mark secrets `sensitive = true`.** Terraform errors if you output a
  sensitive value without it, so this is mostly enforced.
- **Do not output whole resource objects** (`value = aws_instance.this`). It
  couples callers to the provider schema, and one provider upgrade changes your
  module's contract without you touching it.
- **Removing or renaming an output is a breaking change.** There is no `moved`
  block for outputs. Deprecate by keeping the old one and noting it in the
  description for one major version.

---

## 3. When *not* to write a module

Most bad Terraform codebases have too many modules, not too few.

| Situation | Why a module is wrong | Do instead |
|---|---|---|
| **Fewer than ~3 real consumers** | You are designing an interface with a sample size of one. It will be wrong. | Write the resources inline. Extract when the third consumer appears and you can see what actually varies. |
| **Thin wrapper over one resource** | "Resource passthrough": every argument becomes a variable, the module adds a naming indirection and hides the provider docs. Callers must read your module to find out that yes, it supports the argument they want. | Use the resource. If you need conventions, use a shared `locals` file or a naming module that returns strings. |
| **The abstraction will leak** | If you can already predict twenty pass-through variables, the module is not abstracting, it is forwarding. | Expose handles (IDs, ARNs, SG IDs) and let callers attach their own resources. |
| **A well-maintained public module exists** | `terraform-aws-modules/vpc`, `eks`, `rds` have absorbed years of edge cases you have not thought about. | Consume it, pin it, and wrap it only if you need to enforce org policy on top. |
| **It exists to hold company defaults** | A module whose only job is "our tags and our naming" is a policy problem, not a composition problem. | `default_tags` on the provider, plus OPA/Sentinel policy, plus a naming convention documented once. |

The counter-case — when a module **is** right: the same three-to-eight resources
must always be created together, in a specific configuration, with invariants
that matter (a bucket is always encrypted and never public; a node group always
gets the right taints and the right IAM role). That is real abstraction: you are
encoding a decision, not forwarding arguments.

---

## 4. Composition over configuration

The failure mode is the mega-module: one `module "platform"` with eighty
variables that builds a VPC, a cluster, a database and a CDN.

Symptoms:

- The variables file is longer than the resources file.
- Half the variables are named `enable_*` or `create_*`.
- The plan for changing one DNS record is 400 lines.
- Nobody can answer "what does this module create?" without reading it.

Instead:

```hcl
module "vpc" {
  source  = "git::ssh://git@github.com/acme/tf-modules.git//vpc?ref=v2.4.0"
  name    = local.name
  cidr    = "10.40.0.0/16"
  azs     = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
}

module "cluster" {
  source     = "git::ssh://git@github.com/acme/tf-modules.git//eks-cluster?ref=v5.1.2"
  name       = local.name
  vpc_id     = module.vpc.id
  subnet_ids = module.vpc.private_subnet_ids
}

module "app_bucket" {
  source      = "git::ssh://git@github.com/acme/tf-modules.git//s3-bucket?ref=v1.3.0"
  bucket_name = "${local.name}-app-assets"
  kms_key_arn = module.kms.key_arn
}
```

The root module is now the readable summary of what exists. The wiring is
visible. Each module can be versioned and rolled forward independently.

### Nesting depth

Keep it to **two levels below root**, three at the absolute maximum.

Every level of nesting:

- adds a variable that must be threaded through each layer,
- makes `terraform state list` addresses unreadable
  (`module.a.module.b.module.c.aws_instance.x[0]`),
- makes `moved` blocks during refactors painful,
- hides the provider documentation two clicks further from the caller,
- and means a change to a leaf module requires bumping and releasing three
  modules in order.

If you have `module.platform.module.eks.module.node_group.module.iam`, the
refactor is to flatten: let the root compose `eks` and `node-group-iam`
directly.

---

## 5. Providers belong to the root module

**Never put a `provider` block inside a reusable module.** Terraform allows it
for legacy reasons, and it causes two concrete problems:

1. **You cannot remove the module.** Terraform refuses to destroy resources
   whose provider configuration no longer exists, so removing the module call
   leaves you unable to plan a clean destroy. The workaround is manual state
   surgery.
2. **`count`/`for_each` on the module is forbidden.** A module with its own
   provider block cannot be instantiated multiple times, which is usually
   exactly what you want to do.

Instead, declare what you need and let the root pass it in:

```hcl
# modules/replicated-bucket/versions.tf
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.60"
      configuration_aliases = [aws.primary, aws.replica]
    }
  }
}
```

```hcl
# modules/replicated-bucket/main.tf
resource "aws_s3_bucket" "primary" {
  provider = aws.primary
  bucket   = var.bucket_name
}

resource "aws_s3_bucket" "replica" {
  provider = aws.replica
  bucket   = "${var.bucket_name}-replica"
}
```

```hcl
# root
provider "aws" {
  alias  = "euw1"
  region = "eu-west-1"
}

provider "aws" {
  alias  = "use1"
  region = "us-east-1"
}

module "assets" {
  source = "./modules/replicated-bucket"

  providers = {
    aws.primary = aws.euw1
    aws.replica = aws.use1
  }

  bucket_name = "acme-assets"
}
```

`configuration_aliases` requires Terraform 0.15+ and is fully supported in
OpenTofu. Note that a module using it **must** be passed providers explicitly;
there is no implicit inheritance for aliased configurations.

---

## 6. Versioning and pinning

### Semantic versioning for modules

| Change | Bump | Notes |
|---|---|---|
| Adding an optional variable with a default | minor | The most common change |
| Adding an output | minor | Additive |
| Adding a resource that does not affect existing ones | minor | Verify: does it force replacement of anything? |
| Bug fix with no interface change | patch | |
| Removing or renaming a variable | **major** | No exceptions |
| Removing or renaming an output | **major** | No `moved` block exists for outputs |
| Making an optional variable required | **major** | |
| Changing a default such that existing callers get a different plan | **major** | Especially if it forces replacement |
| Changing a resource address without a `moved` block | **major** | And it is a bug even in a major |
| Raising `required_version` or the provider constraint's lower bound | **major** | Callers may be pinned below it |
| Changing a resource address **with** a `moved` block | minor | This is the whole point of `moved` |

That last pair is worth internalizing: `moved` blocks turn what would be a
destroy-and-recreate breaking change into a no-op refactor. Ship them in the
same commit as the rename. See [`import-and-refactor.md`](import-and-refactor.md).

### Pinning at the call site

```hcl
# Registry: pessimistic constraint. Allows 3.2.x and 3.3.x, blocks 4.0.0.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"
}

# Git by TAG. Immutable, auditable.
module "cluster" {
  source = "git::ssh://git@github.com/acme/tf-modules.git//eks-cluster?ref=v5.1.2"
}

# Git by commit SHA. Maximally immutable; use when tags are not protected.
module "legacy" {
  source = "git::ssh://git@github.com/acme/tf-modules.git//legacy?ref=8f2a1c9d4b7e0a3f6c5d2e1b0a9f8e7d6c5b4a39"
}
```

**Never `?ref=main`.** A branch reference means the module you applied last
Tuesday is not the module you apply today, `terraform init -upgrade` silently
changes production behaviour, and your git history cannot tell you what was
deployed. This is the single most common cause of "it worked yesterday" in
Terraform.

Protect the tags. `git tag -d v5.1.2 && git tag v5.1.2 <other-sha> && git push -f`
makes an immutable reference mutable again. Use protected tags or a release
process that only ever moves forward.

### Provider pinning

Constraints go in `required_providers`; **exact resolved versions and checksums
go in `.terraform.lock.hcl`, which you commit**:

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}
```

Root modules commit the lock file. Reusable modules do not — the lock file is
resolved at the root, and a lock file inside a module is ignored. Keep module
constraints **permissive** (`~> 5.60`, not `= 5.60.3`) so that callers can
upgrade; keep root constraints as tight as your upgrade cadence allows.

Generate lock entries for every platform your team and CI use, or Linux CI will
fail on a lock file created on an Apple laptop:

```bash
terraform providers lock \
  -platform=darwin_arm64 \
  -platform=linux_amd64 \
  -platform=linux_arm64
```

**OpenTofu note:** module and provider sources default to OpenTofu's registry.
`hashicorp/aws` resolves through `registry.opentofu.org`. Cross-tool lock files
are not interchangeable, and mixed-tool teams will fight over the lock file
constantly — pick one.

---

## 7. Repo layout

Two workable shapes.

**Monorepo of modules** — best for a platform team owning 10-40 modules:

```
tf-modules/
  .github/workflows/ci.yml
  modules/
    vpc/
      main.tf
      variables.tf
      outputs.tf
      versions.tf
      README.md          # generated by terraform-docs
      examples/
        basic/
          main.tf
        three-tier/
          main.tf
      tests/
        defaults.tftest.hcl
    s3-bucket/
      ...
  CHANGELOG.md
```

Tag as `vpc/v2.4.0` and reference `?ref=vpc/v2.4.0`. One repo, one CI pipeline,
atomic cross-module changes. The downside is that a tag namespace per module
requires discipline, and consumers see churn from modules they do not use.

**Repo per module** — best for modules published to a registry:

```
terraform-aws-vpc/
  main.tf variables.tf outputs.tf versions.tf README.md
  examples/basic/
  tests/
  CHANGELOG.md
```

Clean semver, clean release notes, registry-publishable. Costs you a repo, a CI
config and a release process per module, which is real overhead past a dozen.

### The `examples/` convention

Every module ships at least one example that is **a real, applyable root
module** — its own `versions.tf`, its own provider block, no variables required.

Examples serve three jobs at once: documentation that cannot go stale, the
fixture that `terraform test` and Terratest run against, and the thing CI runs
`validate` and `plan` on for every PR. If an example does not `terraform
validate` in CI, it is documentation, and it will rot.

### terraform-docs

Generate the inputs/outputs tables; do not hand-maintain them.

```yaml
# .terraform-docs.yml
formatter: markdown table
output:
  file: README.md
  mode: inject
  template: |-
    <!-- BEGIN_TF_DOCS -->
    {{ .Content }}
    <!-- END_TF_DOCS -->
settings:
  anchor: true
  default: true
  required: true
  type: true
sort:
  enabled: true
  by: required
```

```bash
terraform-docs .
# In CI, fail if regeneration produces a diff:
terraform-docs . && git diff --exit-code README.md
```

Keep the hand-written parts — purpose, usage examples, caveats, non-goals —
outside the injected markers. The generated table tells you *what* the inputs
are; only a human can tell you *why* the module exists and when not to use it.

---

## 8. A design checklist

Before publishing a module:

- [ ] Every variable has `description` and `type`.
- [ ] Every output has `description`; secrets are `sensitive`.
- [ ] Validation exists for anything with a constrained domain.
- [ ] No `provider` block; aliased providers declared via `configuration_aliases`.
- [ ] Secure-by-default: encryption on, public access off, logging on.
- [ ] No boolean that switches between two architectures.
- [ ] Nesting is at most two levels below root.
- [ ] `required_version` and provider constraints are set and permissive.
- [ ] `examples/` contains at least one applyable root that CI validates.
- [ ] README explains purpose, non-goals and caveats, not just the generated tables.
- [ ] Renames since the last release ship with `moved` blocks.
- [ ] The version bump matches the table in section 6.
