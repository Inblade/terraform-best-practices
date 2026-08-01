# Import and Refactoring

Refactoring Terraform used to mean typing `terraform state mv` at a terminal
and hoping. Since 1.1 the state-manipulating operations have moved into the
configuration language, which means they are reviewable in a PR, repeatable,
idempotent, and executable by CI where nobody is at a keyboard.

Version gating, because it matters:

| Feature | Terraform | OpenTofu |
|---|---|---|
| `moved` blocks | 1.1+ | 1.6+ |
| `import` blocks | 1.5+ | 1.6+ |
| `import` with `for_each` | 1.7+ | 1.7+ |
| `-generate-config-out` | 1.5+ (experimental quality throughout) | 1.6+ |
| `removed` blocks | 1.7+ | 1.7+ |
| `removed` for modules | 1.7+ | 1.7+ |

Everything below assumes Terraform >= 1.9 unless noted.

---

## 1. `moved` blocks

A `moved` block tells Terraform "the thing previously at address A is now at
address B" — rename the state entry, do not destroy and recreate.

Without it, renaming `aws_instance.web` to `aws_instance.frontend` produces a
plan that destroys the instance and creates a new one. With it, the plan is
empty.

### Simple rename

```hcl
moved {
  from = aws_instance.web
  to   = aws_instance.frontend
}

resource "aws_instance" "frontend" {
  ami           = data.aws_ami.al2023.id
  instance_type = "t3.medium"
}
```

### Moving a resource into a module

The common shape when you extract resources into a module:

```hcl
moved {
  from = aws_s3_bucket.artifacts
  to   = module.artifacts.aws_s3_bucket.this
}

moved {
  from = aws_s3_bucket_versioning.artifacts
  to   = module.artifacts.aws_s3_bucket_versioning.this
}

moved {
  from = aws_s3_bucket_public_access_block.artifacts
  to   = module.artifacts.aws_s3_bucket_public_access_block.this
}

module "artifacts" {
  source      = "./modules/s3-bucket"
  bucket_name = "acme-build-artifacts"
}
```

You need one `moved` block per resource. There is no wildcard. For a module with
thirty resources, generate the blocks from `terraform state list`:

```bash
terraform state list \
  | grep '^aws_' \
  | awk '{ printf "moved {\n  from = %s\n  to   = module.artifacts.%s\n}\n\n", $1, $1 }'
```

Then hand-check every line: the addresses inside the module usually differ from
the flat ones (`.this` instead of `.artifacts`), and blindly generated blocks
will move things to addresses that do not exist, which fails the plan — noisily,
which is fine.

### Moving an entire module

```hcl
moved {
  from = module.legacy_vpc
  to   = module.network
}
```

This moves every resource inside it, recursively. This is one of the few
wildcard-ish forms and it is genuinely convenient.

### `count` to `for_each`

The highest-value use of `moved`, because getting this wrong destroys
production. Going from index-keyed to string-keyed addresses:

```hcl
# Before
resource "aws_subnet" "private" {
  count      = length(var.azs)
  vpc_id     = aws_vpc.this.id
  cidr_block = cidrsubnet(var.cidr, 4, count.index)
}
```

```hcl
# After
resource "aws_subnet" "private" {
  for_each = { for i, az in var.azs : az => cidrsubnet(var.cidr, 4, i) }

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = each.value
}

moved {
  from = aws_subnet.private[0]
  to   = aws_subnet.private["eu-west-1a"]
}

moved {
  from = aws_subnet.private[1]
  to   = aws_subnet.private["eu-west-1b"]
}

moved {
  from = aws_subnet.private[2]
  to   = aws_subnet.private["eu-west-1c"]
}
```

The mapping from index to key **must match the order the list had when it was
last applied**, not the order it has in the config today. If someone reordered
`var.azs` between the last apply and now, the indices in state refer to
different AZs than you think. Verify against state, not against the variable:

```bash
terraform state list | grep 'aws_subnet.private'
terraform state show 'aws_subnet.private[0]' | grep availability_zone
```

`moved` blocks accept static addresses only — you cannot generate them with a
`for` expression, and index/key values must be literals. This is deliberate:
the whole point is that the mapping is explicit and reviewable.

### Operational notes

- **A `moved` block that finds nothing at `from` is a no-op**, not an error.
  That is what makes them safe to leave in place and safe to re-run.
- **Leave them in the code for at least one release cycle**, so anyone applying
  an older state still gets the move. Delete them once every consumer has
  applied. In a published module, keeping them for a full major version is
  polite.
- **`moved` cannot change provider or resource type.** Moving
  `aws_alb` to `aws_lb` works only because they are aliases of the same type;
  moving `aws_instance` to `aws_spot_instance_request` does not.
- **Order does not matter.** Terraform resolves chains, so
  `A -> B` plus `B -> C` correctly moves A to C.

---

## 2. `import` blocks

Before 1.5, importing meant `terraform import` at a terminal: one resource at a
time, unreviewable, invisible in git, and not runnable in CI. `import` blocks
fix all four.

```hcl
import {
  to = aws_s3_bucket.legacy_artifacts
  id = "acme-legacy-build-artifacts"
}

resource "aws_s3_bucket" "legacy_artifacts" {
  bucket = "acme-legacy-build-artifacts"
}
```

`terraform plan` now shows the import **as part of the plan**, along with any
changes Terraform intends to make to reconcile the real object with your config.
That preview is the entire value: you find out before applying that your config
says `force_destroy = true` when the real bucket has objects in it.

### Importing many objects

Terraform 1.7+ allows `for_each` on `import`:

```hcl
locals {
  legacy_buckets = {
    artifacts = "acme-legacy-build-artifacts"
    logs      = "acme-legacy-access-logs"
    backups   = "acme-legacy-db-backups"
  }
}

import {
  for_each = local.legacy_buckets
  to       = aws_s3_bucket.legacy[each.key]
  id       = each.value
}

resource "aws_s3_bucket" "legacy" {
  for_each = local.legacy_buckets
  bucket   = each.value
}
```

The `for_each` value must be known at plan time. A `data` source lookup usually
is; anything derived from a resource that does not yet exist is not.

### Generating configuration

```bash
terraform plan -generate-config-out=generated.tf
```

Terraform writes a `resource` block for every `import` block that has no
matching resource in config. It is a genuine time-saver on a large import and it
is **not** production-ready output. Expect to fix:

- Every value is a literal. Account IDs, ARNs, regions and references to other
  resources are all hardcoded strings that should be references or variables.
- Read-only and computed attributes are sometimes emitted, and the config will
  not validate until you delete them.
- Default values are written out explicitly, so the file is three times longer
  than a hand-written equivalent.
- Provider coverage is uneven. Providers that do not fully implement the import
  schema produce incomplete blocks or fail outright.
- `sensitive` values are emitted as `null` with a comment; you must supply them.
- It refuses to overwrite an existing file, and it will not run if any `import`
  block already has a matching resource.

Workflow that works: generate, then diff-and-rewrite by hand into your actual
module structure, then iterate `terraform plan` until it is empty. Do not commit
the generated file as-is.

### Legacy `terraform import`

```bash
terraform import 'aws_s3_bucket.legacy_artifacts' acme-legacy-build-artifacts
```

Still works, still occasionally necessary (it can be scripted against a state
you cannot easily add config to, and it works for cross-state moves). But:

| | `terraform import` CLI | `import` block |
|---|---|---|
| Reviewable in a PR | No | Yes |
| Shows what will change before doing it | No — imports immediately | Yes, as part of the plan |
| Runnable in CI | Awkwardly | Naturally |
| Idempotent | No — errors if already in state | Yes — no-op once imported |
| Bulk operations | Shell loop | `for_each` |
| Recorded in git history | No | Yes |

Prefer the block form. After the apply succeeds, the `import` block is inert; it
is conventional to delete it in a follow-up PR once the import has landed in
every environment.

---

## 3. `removed` blocks

Terraform 1.7+ replaces `terraform state rm` with a declarative form: drop the
resource from state without destroying the real object.

```hcl
removed {
  from = aws_iam_role.legacy_ci

  lifecycle {
    destroy = false
  }
}
```

Delete the `resource` block at the same time. The `lifecycle { destroy = false }`
is the whole point — it is what distinguishes "forget this" from "delete this".
The block is **required**; omitting it is a configuration error, which is good
design: there is no ambiguous default.

For a whole module:

```hcl
removed {
  from = module.legacy_monitoring

  lifecycle {
    destroy = false
  }
}
```

Setting `destroy = true` makes it a normal destroy — useful when you want to
delete a module's resources but the module source is already gone from your
filesystem.

Why this is better than `terraform state rm`:

- It appears in the plan, so you see exactly which addresses are being forgotten
  before you agree to it.
- It is in the PR, so a second person sees it.
- It runs in CI.
- It is a no-op if the address is already gone, so a re-run is safe.

Same lifecycle as `moved`: leave the block in the code for one release, then
remove it.

---

## 4. Breaking apart a monolith state

This is the operation people are most afraid of, and rightly — it is where
production gets deleted. The procedure below has a verification gate at every
step and a rollback from every step.

### Step 0 — Back up

```bash
cd envs/prod/monolith
terraform state pull > ~/secure/monolith-$(date -u +%Y%m%dT%H%M%SZ).json
jq '.serial, .lineage, (.resources | length)' ~/secure/monolith-*.json
```

Also confirm the state bucket has versioning on. If it does not, stop and fix
that first.

### Step 1 — Inventory

```bash
terraform state list | tee /tmp/inventory.txt | wc -l

# Group by type to see the shape of the thing.
terraform state list | sed 's/\[.*//' | sort | uniq -c | sort -rn | head -30
```

### Step 2 — Choose the seam

Good seams, in priority order:

1. **Lifecycle / rate of change.** Networking changes monthly; app services
   change daily. Splitting these means a daily deploy cannot touch the VPC.
2. **Blast radius.** Anything stateful (databases, buckets with data, KMS keys)
   goes in its own state with restrictive IAM. Nothing that runs on a deploy
   pipeline should be able to plan a destroy against it.
3. **Team ownership.** If two teams need to apply, and their changes never
   interact, split. If they interact constantly, do not — you are just moving
   the coordination into remote-state lookups.
4. **Provider or account boundary.** Different account or region is a natural
   seam and often forced anyway.

Bad seams: by AWS service (`all-the-iam/`, `all-the-sgs/`), by file name, or
"whatever makes the directories even in size". These create states with mutual
dependencies in both directions, which is worse than the monolith.

Write down the seam as an explicit list of addresses:

```bash
grep -E '^(module\.data\.|aws_db_|aws_rds_|aws_elasticache_)' /tmp/inventory.txt \
  > /tmp/moving-to-data.txt
wc -l /tmp/moving-to-data.txt
```

### Step 3 — Build the new root

New directory, new backend key, its own provider block. Copy the relevant HCL
across. Anything the moving resources reference from the staying side becomes an
input.

```hcl
# envs/prod/data/versions.tf
terraform {
  required_version = ">= 1.9"

  backend "s3" {
    bucket       = "acme-tfstate-prod-euw1"
    key          = "prod/data/terraform.tfstate"   # NEW key. Never reuse.
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}
```

**Match the provider configuration exactly**, including `default_tags`. See the
gotchas below.

### Step 4 — Populate the new state with `import` blocks

This is the safest mechanism, because it never touches the source state.

```bash
# Get the real IDs for everything moving.
while read -r addr; do
  id=$(terraform state show -no-color "$addr" | awk '/^ +id +=/ {print $3; exit}')
  echo "import { to = ${addr#module.data.}  id = ${id} }"
done < /tmp/moving-to-data.txt
```

Real IDs vary in form per resource type (an `aws_iam_role_policy_attachment` is
`role/policy-arn`, an `aws_route53_record` is
`zoneid_name_type`), so consult the provider's import documentation rather than
assuming `id` is always the answer.

```hcl
# envs/prod/data/imports.tf
import {
  to = aws_db_instance.main
  id = "acme-prod-main"
}

import {
  to = aws_db_subnet_group.main
  id = "acme-prod-db-subnets"
}
```

```bash
cd envs/prod/data
terraform init
terraform plan -out=verify.tfplan
```

The **alternative** to imports is state surgery: `terraform state pull` on the
source, `state mv -state=... -state-out=...` between local files, `state push`
to the new backend. It is faster for hundreds of resources and it is riskier,
because a mistake writes a broken state rather than failing a plan. Use it only
when import IDs are genuinely unavailable, and only with backups of both states.

### Step 5 — The acceptance gate

**The new root must plan to exactly zero changes.** Not "only tags". Not "just a
description". Zero.

```bash
terraform show -json verify.tfplan | jq '
  [.resource_changes[]
   | select(.change.actions != ["no-op"])
   | {address, actions: .change.actions}]
'
# Must be []
```

Anything non-empty means the new root's config does not match reality. Fix the
config, re-plan, repeat. Do **not** apply "just the small diff" — that diff is
the evidence that you have misunderstood something, and the next diff might be a
replacement of the database.

Rollback at this point is free: delete the new state object, delete the
directory. Nothing has changed in the source root.

### Step 6 — Remove from the old root

Only now. Delete the resource blocks from the old root and add `removed` blocks:

```hcl
# envs/prod/monolith/removed.tf
removed {
  from = aws_db_instance.main
  lifecycle { destroy = false }
}

removed {
  from = aws_db_subnet_group.main
  lifecycle { destroy = false }
}
```

```bash
cd envs/prod/monolith
terraform plan   # MUST show only "will no longer be managed", zero destroys
terraform apply
```

Read that plan character by character. A single `will be destroyed` line means
you missed a `removed` block, and applying it deletes the database that is now
also managed by the new root.

Rollback here: `terraform state push -force` the backup from step 0.

### Step 7 — Reconnect the dependencies

Resources that used to reference each other directly now live in different
states. Options, best first:

**1. Pass values as variables** from a shared source of truth (tfvars generated
by your pipeline, or a config repo). Simple, explicit, no runtime coupling.

**2. Data sources against the real API.** Look the thing up by tag or name:

```hcl
data "aws_vpc" "main" {
  tags = { Name = "acme-prod" }
}
```

Requires a naming/tagging convention you actually enforce, but creates no
coupling between states and no read permissions on another team's state.

**3. Parameter Store / Secrets Manager as the interface.** The producing state
writes, the consuming state reads:

```hcl
# producer
resource "aws_ssm_parameter" "vpc_id" {
  name  = "/platform/prod/vpc_id"
  type  = "String"
  value = aws_vpc.this.id
}

# consumer
data "aws_ssm_parameter" "vpc_id" {
  name = "/platform/prod/vpc_id"
}
```

**4. `terraform_remote_state`.** Works, and is the option I reach for last:

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "acme-tfstate-prod-euw1"
    key    = "prod/network/terraform.tfstate"
    region = "eu-west-1"
  }
}
```

It requires the consumer to have **read access to the producer's entire state
file**, including its secrets, which undoes much of the isolation you just built.
It also couples you to the producer's output names forever.

### Step 8 — Verify both roots

```bash
for d in envs/prod/monolith envs/prod/data; do
  terraform -chdir="$d" plan -detailed-exitcode -no-color > /dev/null
  echo "$d -> exit $?"   # 0 means clean
done
```

Then leave it a week before doing the next seam. Splitting one state at a time
means one thing to roll back.

---

## 5. Gotchas

**`default_tags` drift.** If the source provider had `default_tags` and the new
one does not (or has different ones), every resource shows a tag diff and the
zero-change gate fails. Copy the provider block verbatim, then change it in a
separate commit. The reverse is worse: if the new root adds `default_tags`, the
first apply mutates every resource.

**Resources with provider-generated names.** Anything using `name_prefix` — IAM
roles, launch templates, security groups — has a real name the config does not
contain. If your new config specifies `name` where the original used
`name_prefix`, the plan proposes a replacement. Match the original argument, not
the original value.

**Data sources are not imported.** They are re-evaluated in the new root. If the
data source's filter matched something in the source root's context (a region, a
provider alias, an account), verify it matches the same thing in the new one. A
data source silently matching a different object is one of the nastiest failure
modes here because there is no state entry to inspect.

**Implicit dependencies become invisible.** `aws_instance` referencing
`aws_security_group.id` had an ordering guarantee. Across states, it does not.
Destroy ordering in particular is no longer enforced: you can now destroy the
security group's state while instances still reference it, and get an API error
mid-apply. Document the ordering; do not rely on Terraform for it.

**`for_each`/`count` addresses must match exactly.** `aws_subnet.this["a"]` and
`aws_subnet.this[0]` are different addresses. If the new module keys differently
from the old, you need `moved` blocks *inside* the new root after importing, or
import directly to the new addresses.

**Module addresses.** Importing into a module means the full address:
`module.data.aws_db_instance.main`, not `aws_db_instance.main`. Easy to get
wrong when generating imports from a `state list` of the old root.

**Provider version skew.** If the new root resolves a newer provider, attribute
defaults may have changed and the zero-change gate fails for reasons unrelated
to your split. Pin the new root to the same provider version as the old one for
the migration, then upgrade separately.

**Lock contention during the migration.** Both roots are being planned
repeatedly. Make sure nobody else is applying the monolith while you work.

---

## 6. Provider renames and `state replace-provider`

Every resource in state records the provider that manages it, by fully-qualified
name. When a provider moves in the registry — a namespace change, a fork, a
community provider adopted by a vendor — that recorded FQN no longer resolves
and Terraform refuses to plan.

```bash
# What does this state actually reference?
terraform providers

# Legacy pre-0.13 shorthand, seen in very old states.
terraform state replace-provider \
  'registry.terraform.io/-/aws' \
  'registry.terraform.io/hashicorp/aws'

# Namespace change on a community provider.
terraform state replace-provider \
  'registry.terraform.io/mongey/kafka' \
  'registry.terraform.io/Mongey/kafka'

# Migrating a state to OpenTofu's registry.
terraform state replace-provider \
  'registry.terraform.io/hashicorp/aws' \
  'registry.opentofu.org/hashicorp/aws'
```

Practicalities:

- **Back up first.** This command rewrites every matching resource in state.
- It prompts for confirmation and lists affected resources; read the list.
- It changes **state only**. You must also update `required_providers` in code,
  and `terraform init -upgrade` afterwards.
- The two providers must be schema-compatible. Replacing `hashicorp/aws` with an
  unrelated provider produces a state that cannot be decoded.
- There is no declarative block form for this — it remains a CLI operation. It
  is also one of the few state commands that is genuinely hard to get wrong,
  because a mismatch fails loudly at plan rather than silently.

**OpenTofu note:** `tofu state replace-provider` behaves identically, and this
is the standard step when migrating an existing Terraform state to OpenTofu
alongside re-running `init -upgrade` to regenerate the lock file. The state
format itself is compatible in the 1.x line; the lock file is not.

---

## 7. Refactoring checklist

- [ ] Backup taken (`terraform state pull`), stored off the machine doing the work.
- [ ] Bucket versioning confirmed on.
- [ ] Every rename has a `moved` block; every import has an `import` block;
      every de-registration has a `removed` block with `destroy = false`.
- [ ] No `terraform state mv` or `state rm` typed at a terminal for anything that
      could have been a block.
- [ ] Plan reviewed by a second person before apply.
- [ ] Acceptance gate: the target root plans to **zero** changes.
- [ ] Old root's plan shows only "no longer managed", zero destroys.
- [ ] Rollback procedure written down before starting, not improvised.
- [ ] `moved`/`removed`/`import` blocks cleaned up one release later.
- [ ] Both roots plan clean (`-detailed-exitcode` returns 0) after the dust settles.
