# Anti-Patterns

Fourteen patterns I have either shipped myself or been paged about. Each one is
listed as symptom, why it hurts, and what to do instead. None of them are
theoretical.

They are roughly ordered by how much damage they do when they go wrong.

---

## 1. `count` over a list of named things

**Symptom.** `count = length(var.users)` or `count = length(var.buckets)`, where
the list elements are distinct named objects rather than interchangeable copies.

**Why it hurts.** `count` keys state by **position**. Remove an element from the
middle and every element after it shifts down by one. Terraform sees this as
"resource at index 1 changed its name" and destroys/recreates everything from
that index onward.

Concretely. Given `var.users = ["alice", "bob", "carol"]`:

```
aws_iam_user.this[0]  -> alice
aws_iam_user.this[1]  -> bob
aws_iam_user.this[2]  -> carol
```

Alice leaves. `var.users = ["bob", "carol"]`. The plan:

```
# aws_iam_user.this[0] must be replaced
-/+ name = "alice" -> "bob"        # forces replacement
# aws_iam_user.this[1] must be replaced
-/+ name = "bob" -> "carol"        # forces replacement
# aws_iam_user.this[2] will be destroyed
```

Three replacements to remove one user. Bob and Carol's IAM users are deleted and
recreated — new ARNs, dropped access keys, broken assume-role trust policies
elsewhere. For IAM users that is an outage. For EBS volumes or RDS instances it
is data loss.

**Do this instead.**

```hcl
# Bad
variable "users" {
  type = list(string)
}

resource "aws_iam_user" "this" {
  count = length(var.users)
  name  = var.users[count.index]
}
```

```hcl
# Good - keyed by a stable identifier
variable "users" {
  type = set(string)
}

resource "aws_iam_user" "this" {
  for_each = var.users
  name     = each.key
}
```

Now removing alice produces exactly one destroy and nothing else.

**Rule of thumb:** `count` is for *N interchangeable copies* (three identical
NAT gateways) and for the `count = var.enabled ? 1 : 0` conditional. Everything
else is `for_each`.

Migrating an existing `count` to `for_each` requires `moved` blocks or you get
the exact destruction described above — see
[`import-and-refactor.md`](import-and-refactor.md).

---

## 2. `for_each` over values not known at plan time

**Symptom.**

```
Error: Invalid for_each argument

The "for_each" map includes keys derived from resource attributes that cannot
be determined until apply, and so Terraform cannot determine the full set of
keys that will identify the instances of this resource.
```

**Why it hurts.** Terraform must know the **keys** of a `for_each` at plan time,
because keys are resource addresses and the plan is a list of addresses. Values
may be unknown; keys may not. Deriving keys from something that does not exist
yet is unresolvable.

```hcl
# Bad - the bucket does not exist yet, so its ARN is unknown at plan time,
# and here the ARN is being used to build the KEY.
resource "aws_s3_bucket" "this" {
  for_each = toset(var.bucket_names)
  bucket   = each.key
}

resource "aws_iam_policy" "per_bucket" {
  for_each = { for b in aws_s3_bucket.this : b.arn => b.id }   # keys unknown
  name     = "access-${each.value}"
  policy   = data.aws_iam_policy_document.access[each.key].json
}
```

**Do this instead.** Key off the static input; use the unknown value only in the
body.

```hcl
# Good - keys come from var.bucket_names, which is known at plan time.
resource "aws_iam_policy" "per_bucket" {
  for_each = toset(var.bucket_names)

  name   = "access-${each.key}"
  policy = data.aws_iam_policy_document.access[each.key].json
}
```

Other fixes, in order of preference:

1. Restructure so keys come from configuration, not from resources. Works 90% of
   the time and is always the right answer when it does.
2. Use `-target` to apply the producing resources first, then apply normally.
   Documented in the error message, ugly, occasionally necessary.
3. Split into two root modules with an explicit apply order. Correct when the
   dependency really is a two-phase bootstrap (create a cluster, then configure
   things inside it with the Kubernetes provider).

`toset()` on a list built with `for` over a data source is usually fine — data
sources are read during plan. The problem is specifically *resource* attributes.

---

## 3. Hardcoded environment names, account IDs and regions inside modules

**Symptom.**

```hcl
# Bad - inside modules/rds/main.tf
resource "aws_db_instance" "this" {
  identifier     = "prod-postgres"
  instance_class = var.env == "prod" ? "db.r6g.2xlarge" : "db.t4g.medium"
  kms_key_id     = "arn:aws:kms:eu-west-1:111122223333:key/8f0e...c31a"
}

data "aws_ami" "app" {
  filter {
    name   = "image-id"
    values = ["ami-0abc123def4567890"]   # only exists in eu-west-1
  }
}
```

**Why it hurts.** The module is now a single-environment module wearing a
module's clothes. The `var.env == "prod"` conditional means the module knows
about your environments, so adding a fourth one means editing the module. The
account ID means it cannot be used in another account. The AMI ID means it
cannot be used in another region, and the failure is a confusing "no AMI found"
rather than a clear error.

**Do this instead.** The module takes values; the root supplies them.

```hcl
# Good - modules/rds/variables.tf
variable "identifier" {
  description = "RDS instance identifier. Must be unique per region per account."
  type        = string
}

variable "instance_class" {
  description = "RDS instance class, e.g. db.r6g.2xlarge."
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key for storage encryption."
  type        = string
}
```

```hcl
# Good - envs/prod/data/main.tf
module "postgres" {
  source = "../../../modules/rds"

  identifier     = "prod-postgres"
  instance_class = "db.r6g.2xlarge"
  kms_key_arn    = aws_kms_key.rds.arn
}
```

Environment differences are now visible in a diff between `envs/prod` and
`envs/staging`, which is exactly where a reviewer looks for them. Use
`data.aws_caller_identity.current.account_id` and `data.aws_region.current` in
the root when you need them dynamically.

---

## 4. The giant root module

**Symptom.** One root module, thousands of resources. `terraform plan` takes 20
minutes. The team has a Slack convention for "who has the lock". Nobody runs a
plan speculatively.

**Why it hurts.**

- Refresh is one or more API calls per resource; at 3000 resources you are
  looking at 8-20 minutes and intermittent throttling.
- One lock for everything, so the team serializes. A DNS change waits behind a
  cluster upgrade.
- Blast radius is total. One bad `for_each` and the plan proposes destroying
  production.
- People reach for `-refresh=false` and `-target` to survive, which compounds
  the problem (see #6).
- A single `state rm` mistake affects everything.

**Do this instead.** Split by rate of change and blast radius:

```
envs/prod/
  network/     # VPC, TGW, DNS zones     - monthly, high blast radius
  data/        # RDS, ElastiCache, S3    - rarely, catastrophic blast radius
  platform/    # EKS, addons, IRSA       - weekly
  apps/        # services, ALBs, records - daily, low blast radius
```

The `apps/` state can be applied by CI on every merge. The `data/` state is
applied by a human with a different role. See
[`state-management.md`](state-management.md) for the comparison table and
[`import-and-refactor.md`](import-and-refactor.md) for the split procedure.

Target: **a plan should complete in under two minutes.** If it does not, you
have a splitting problem, not a patience problem.

---

## 5. Workspaces used to model genuinely different environments

**Symptom.**

```hcl
locals {
  instance_count = terraform.workspace == "prod" ? 6 : 1
  instance_type  = terraform.workspace == "prod" ? "m6i.2xlarge" : "t3.small"
  multi_az       = terraform.workspace == "prod"
  domain         = terraform.workspace == "prod" ? "acme.com" : "${terraform.workspace}.dev.acme.com"
}
```

**Why it hurts.**

- **One backend configuration, one set of credentials.** Whatever credentials
  can apply dev can apply prod. There is no IAM boundary between environments.
- **The selected workspace is invisible ambient state.** `terraform apply` after
  forgetting `terraform workspace select` is a real and recurring outage. There
  is no confirmation prompt naming the environment.
- **No per-environment provider configuration.** Different region, different
  account, different `default_tags` — none of it is expressible.
- **The conditionals metastasize.** Ten `terraform.workspace ==` expressions
  become forty, and the prod configuration is no longer readable in one place.
- All workspaces live under one backend key prefix, so state growth and lock
  contention are shared.

**Do this instead.** Directory per environment, each with its own backend block,
provider block and IAM role. The duplication is the point: `diff envs/staging
envs/prod` is a document nobody has to write.

**Workspaces are fine for:** ephemeral copies of an identical stack — per-PR
review environments, per-developer sandboxes, per-tenant instances of the same
thing. The distinguishing question is "do these differ in any way a reviewer
would want to see?" If yes, use directories.

---

## 6. `-target` as a routine workflow

**Symptom.** The runbook says `terraform apply -target=module.app`. People know
which targets to use for which change.

**Why it hurts.** Terraform prints a warning for a reason:

> Note: The -target option is not for routine use, and is provided only for
> exceptional situations such as recovering from errors or mistakes.

A targeted apply produces a **partial** application of the plan. The resulting
state is consistent with neither the previous config nor the new one. Resources
that should have been updated together are not. The next full plan surfaces the
leftovers, often days later and usually to someone else.

It also hides the actual problem, which is almost always #4.

**Do this instead.**

```bash
# Bad, as a habit
terraform apply -target=module.app.aws_ecs_service.api

# Good - the state is small enough that a full plan is cheap
terraform apply
```

Split the state so full plans are fast. Legitimate `-target` uses: recovering
from a crashed apply, working around a provider bug, breaking a
chicken-and-egg during a bootstrap. All of them are incidents, and all of them
should be followed by a clean full plan before you walk away.

---

## 7. Committing `.tfvars` with secrets, or relying on state secrecy

**Symptom.** `prod.tfvars` in git containing `db_password = "..."`. Or a
`random_password` resource, with the reasoning "state is in a private bucket".

**Why it hurts.** Committed secrets are compromised the moment anyone clones the
repo, and `git filter-repo` does not un-clone it. State secrets are visible to
anyone with `s3:GetObject` on the state bucket, which is usually a wider group
than anyone realises — including every CI job that runs a plan.

`sensitive = true` redacts CLI output only. The value is in state in plaintext,
in the plan file in plaintext, and in the CI artifact you just uploaded.

**Do this instead.**

```hcl
# Bad
resource "random_password" "db" {
  length = 32
}

resource "aws_db_instance" "main" {
  password = random_password.db.result   # now permanently in state
}
```

```hcl
# Good - the secret is generated and held by the secrets manager;
# Terraform never sees the value in a way that persists.
resource "aws_secretsmanager_secret" "db" {
  name = "prod/postgres/master"
}

ephemeral "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
}

resource "aws_db_instance" "main" {
  # Write-only argument: passed to the API, never written to state. TF 1.11+.
  password_wo         = ephemeral.aws_secretsmanager_secret_version.db.secret_string
  password_wo_version = 1
}
```

`ephemeral` resources need Terraform 1.10+; write-only (`_wo`) arguments need
1.11+ and per-resource provider support. Below those versions the mitigation is
purely access control: lock down the state bucket, audit KMS `Decrypt`, and
treat state read access as production credential access. OpenTofu's client-side
state encryption is a different answer to the same problem.

`.gitignore` `*.tfvars` on day one, with an exception for `*.tfvars.example`.

---

## 8. Unpinned versions, or pinning to a branch

**Symptom.**

```hcl
# Bad
module "vpc" {
  source = "git::https://github.com/acme/tf-modules.git//vpc"          # no ref
}

module "eks" {
  source = "git::https://github.com/acme/tf-modules.git//eks?ref=main" # branch
}

terraform {
  required_providers {
    aws = { source = "hashicorp/aws" }   # no version constraint
  }
}
```

**Why it hurts.** The configuration in git no longer describes what is deployed.
`terraform init -upgrade` in CI silently changes production behaviour with no
diff and no review. A colleague's merge to `main` in the module repo becomes
part of your next apply. Debugging "it worked yesterday" is impossible because
yesterday's code is not recoverable.

Unpinned providers are worse in one specific way: a major provider release
changes attribute defaults, and the plan proposes replacing resources you did
not touch.

**Do this instead.**

```hcl
# Good
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"                       # registry: allows 5.13.x-5.x
}

module "eks" {
  source = "git::https://github.com/acme/tf-modules.git//eks?ref=v5.1.2"  # tag
}

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

And **commit `.terraform.lock.hcl`** in every root module. The constraint says
what is acceptable; the lock file says what is actually installed, with
checksums. Generate entries for every platform your team and CI use:

```bash
terraform providers lock -platform=linux_amd64 -platform=darwin_arm64
```

Protect the git tags in the module repo so `v5.1.2` cannot be moved.

---

## 9. `depends_on` masking a missing implicit dependency

**Symptom.** `depends_on` sprinkled on resources that already reference each
other, or added because "the apply failed once and this fixed it".

```hcl
# Bad - the reference already creates the dependency; depends_on adds nothing
# but noise, and encourages the next person to add more.
resource "aws_instance" "web" {
  subnet_id  = aws_subnet.public.id
  depends_on = [aws_subnet.public, aws_vpc.this, aws_internet_gateway.this]
}
```

**Why it hurts.** Terraform builds the dependency graph from attribute
references automatically. Redundant `depends_on` is noise that hides the two or
three places where it is genuinely needed. Worse, `depends_on` on a **module**
makes everything inside it wait for everything in the dependency, serializing
applies and turning a 4-minute apply into 12.

It also papers over the real bug. If an apply fails on ordering, there is
usually a missing reference — you passed a hardcoded name where you should have
passed `other_resource.name`.

**Do this instead.** Use references, and reserve `depends_on` for dependencies
Terraform genuinely cannot see:

```hcl
# Good - the reference is the dependency
resource "aws_instance" "web" {
  subnet_id = aws_subnet.public.id
}

# Good - a REAL implicit dependency: the instance needs the role's policy
# attached to be able to boot successfully, but nothing in the instance's
# arguments references the attachment.
resource "aws_instance" "app" {
  iam_instance_profile = aws_iam_instance_profile.app.name

  depends_on = [aws_iam_role_policy_attachment.app_s3_read]
}
```

Every `depends_on` deserves a comment explaining what the invisible dependency
is. If you cannot write that comment, delete the `depends_on`.

---

## 10. `local-exec` / `null_resource` as glue

**Symptom.**

```hcl
# Bad
resource "null_resource" "db_migrate" {
  provisioner "local-exec" {
    command = "psql -h ${aws_db_instance.main.address} -f schema.sql"
  }

  triggers = {
    always = timestamp()
  }
}

resource "null_resource" "wait" {
  provisioner "local-exec" {
    command = "sleep 60"
  }
}
```

**Why it hurts.**

- **Invisible to plan.** The plan says "null_resource will be created". It does
  not say what the script does or what it will change. Review is impossible.
- **Not idempotent.** Terraform tracks whether the provisioner *ran*, not what it
  *did*. A partial failure leaves the resource tainted and re-runs the whole
  script.
- **Depends on the machine running Terraform.** `psql`, `aws`, `jq`, `bash`
  version, network path to a private subnet. It works on the author's laptop and
  fails in CI.
- **No destroy semantics.** Nothing undoes it.
- **`triggers = { always = timestamp() }`** means it runs on every apply, so
  every plan is dirty and nobody can tell a clean plan from a dirty one.
- **`sleep` as a synchronisation primitive** is a race condition that has not
  happened yet.

**Do this instead.**

```hcl
# Good - a real provider that models the thing, with real state and a real plan
resource "postgresql_database" "app" {
  name  = "app"
  owner = postgresql_role.app.name
}
```

Or move it out of Terraform entirely, into the pipeline step where it belongs:

```yaml
- name: Terraform apply
  run: terraform apply -auto-approve tfplan

- name: Run database migrations
  run: ./migrate.sh --url "$(terraform output -raw db_url)"
```

Migrations, application deploys and data seeding are pipeline concerns.
Terraform's job is to produce the database and hand you its address.

Legitimate `local-exec` uses do exist — a one-off `aws` CLI call for something
with no provider coverage — but they should be rare, commented, and idempotent.

---

## 11. `lifecycle { ignore_changes = all }` as a band-aid

**Symptom.**

```hcl
# Bad
resource "aws_ecs_service" "api" {
  name            = "api"
  task_definition = aws_ecs_task_definition.api.arn

  lifecycle {
    ignore_changes = all
  }
}
```

**Why it hurts.** The resource is now unmanaged in everything but name.
Terraform will create it and never update it again. Drift accumulates silently
and permanently. Six months later nobody knows whether the code describes
reality, and the answer is no. The next person to remove the `ignore_changes`
gets a plan proposing 40 changes with no way to tell which are intentional.

**Do this instead.** Ignore the specific attributes that something else
legitimately owns, with a comment saying what owns them:

```hcl
# Good
resource "aws_ecs_service" "api" {
  name            = "api"
  task_definition = aws_ecs_task_definition.api.arn

  lifecycle {
    # The deploy pipeline updates the task definition revision and the
    # autoscaler owns desired_count. Terraform owns everything else.
    ignore_changes = [task_definition, desired_count]
  }
}
```

If you find yourself wanting `ignore_changes = all`, the honest options are:
stop managing the resource in Terraform (use a data source instead), or fix the
thing that keeps changing it. `ignore_changes = all` is neither.

Related trap: `ignore_changes = [tags]` when the real problem is that a tagging
policy or another tool adds tags. Use `default_tags` and ignore only the
specific keys.

---

## 12. Deeply nested modules and pass-through variable sprawl

**Symptom.** `module.platform.module.eks.module.node_group.module.iam.aws_iam_role.this`,
and a variable named `enable_node_group_iam_boundary` that exists in four
`variables.tf` files with identical descriptions.

**Why it hurts.**

- Adding one option means editing four modules and releasing them in dependency
  order.
- State addresses become unreadable, and `moved` blocks during refactors become
  nightmarish.
- A reviewer cannot answer "what does this create?" without opening four repos.
- The middle layers add no logic. They are postal services for variables.
- Provider documentation is now four clicks away from the caller.

**Do this instead.** Flatten. Compose at the root:

```hcl
# Bad
module "platform" {
  source = "./modules/platform"   # which wraps eks, which wraps node_group, ...

  enable_node_group_iam_boundary = true
  node_group_iam_boundary_arn    = "arn:aws:iam::111122223333:policy/boundary"
  node_group_instance_types      = ["m6i.large"]
  node_group_desired_size        = 3
  # ...40 more pass-through variables
}
```

```hcl
# Good - the root composes small modules; the wiring is visible
module "cluster" {
  source     = "./modules/eks-cluster"
  name       = local.name
  vpc_id     = module.vpc.id
  subnet_ids = module.vpc.private_subnet_ids
}

module "node_group" {
  source = "./modules/eks-node-group"

  cluster_name        = module.cluster.name
  subnet_ids          = module.vpc.private_subnet_ids
  instance_types      = ["m6i.large"]
  desired_size        = 3
  permissions_boundary = "arn:aws:iam::111122223333:policy/boundary"
}
```

Depth limit: **two levels below root.** Three is a smell. Four is a refactor
ticket. If a variable exists only to be forwarded unchanged, the layer it passes
through should not exist.

---

## 13. `dynamic` blocks everywhere

**Symptom.** A 30-line resource turned into 90 lines of nested `dynamic` with
`for_each = try(var.config.rules, [])` and `lookup(rule.value, "x", null)`
throughout.

**Why it hurts.** `dynamic` blocks are hard to read, hard to diff, and produce
error messages that point at the `content` block rather than at the caller's
input. `try()` and `lookup()` with defaults hide typos: a misspelled key
silently becomes the default instead of failing.

The usual driver is a variable typed `any` or `map(any)`, which is #3's cousin —
you gave up type safety, so now you need defensive code everywhere.

```hcl
# Bad - unreadable, and a typo in "form_port" silently yields null
resource "aws_security_group" "this" {
  dynamic "ingress" {
    for_each = try(var.config.ingress, [])
    content {
      from_port   = lookup(ingress.value, "from_port", 0)
      to_port     = lookup(ingress.value, "to_port", 0)
      protocol    = lookup(ingress.value, "protocol", "tcp")
      cidr_blocks = lookup(ingress.value, "cidr_blocks", [])
      description = lookup(ingress.value, "description", null)
    }
  }
  dynamic "egress" { /* ...another 8 lines... */ }
}
```

```hcl
# Good - a typed variable, separate rule resources, one instance per rule.
# Adding or removing a rule is a one-line plan diff.
variable "ingress_rules" {
  description = "Ingress rules keyed by a stable name."
  type = map(object({
    from_port   = number
    to_port     = number
    protocol    = optional(string, "tcp")
    cidr_ipv4   = string
    description = string
  }))
  default = {}
}

resource "aws_vpc_security_group_ingress_rule" "this" {
  for_each = var.ingress_rules

  security_group_id = aws_security_group.this.id
  from_port         = each.value.from_port
  to_port           = each.value.to_port
  ip_protocol       = each.value.protocol
  cidr_ipv4         = each.value.cidr_ipv4
  description       = each.value.description
}
```

`dynamic` is right when the provider genuinely models something as a repeated
nested block with no separate resource (`aws_s3_bucket_lifecycle_configuration`
rules, IAM policy document statements, ASG tag blocks). It is wrong as a way to
make a resource "configurable". Two or three static blocks beat one dynamic
block that produces two or three blocks.

---

## 14. Copy-pasted environments that drift, and ClickOps with no drift detection

**Symptom.** `envs/prod/` and `envs/staging/` started identical. A year later
prod has a WAF, staging does not; staging is on provider 5.40, prod on 5.12; the
prod ALB has an attribute someone set in the console during an incident and
never put back.

**Why it hurts.** Staging stops predicting prod, which is the only reason
staging exists. A change tested in staging fails in prod for reasons nobody can
enumerate. Console changes are invisible until the next apply proposes reverting
them, usually at the worst possible time — and if the apply is `-auto-approve`,
the revert happens without anyone reading it.

**Do this instead.**

Directory-per-env does not mean copy-paste-per-env. The environments call the
**same modules at the same version**; only the inputs differ:

```hcl
# envs/staging/apps/main.tf
module "api" {
  source = "git::ssh://git@github.com/acme/tf-modules.git//ecs-service?ref=v4.2.0"

  name          = "api"
  desired_count = 1
  cpu           = 512
  memory        = 1024
}
```

```hcl
# envs/prod/apps/main.tf
module "api" {
  source = "git::ssh://git@github.com/acme/tf-modules.git//ecs-service?ref=v4.2.0"

  name          = "api"
  desired_count = 6
  cpu           = 2048
  memory        = 4096
}
```

A `diff` between the two files should be short and should consist entirely of
things you meant. Add a CI check that fails if module versions differ across
environments for more than N days.

For ClickOps: **you cannot prevent console changes, so detect them.**

```bash
terraform plan -detailed-exitcode -lock=false
# 0 = clean, 1 = error, 2 = drift
```

Run that nightly against every environment with a read-only role, and open a
ticket on exit code 2 (there is a full workflow in
[`state-management.md`](state-management.md)). Then close the loop
organisationally: read-only console access for humans by default, break-glass
roles that alert when assumed, and a rule that any emergency console change gets
reflected in code within one business day. The alerting matters more than the
prevention — a drift that is found in 12 hours is a chore; one found in six
months is an archaeology project.

---

## Quick reference

| # | Anti-pattern | Cheapest fix |
|---|---|---|
| 1 | `count` over named things | `for_each` with stable keys + `moved` blocks |
| 2 | `for_each` over unknown values | Key off static config, not resource attributes |
| 3 | Hardcoded env/account/region in modules | Variables in, values from the root |
| 4 | Giant root module | Split by rate of change and blast radius |
| 5 | Workspaces for differing environments | Directory per environment |
| 6 | `-target` as routine | Fix #4 |
| 7 | Secrets in tfvars or state | Secrets manager + ephemeral / write-only args |
| 8 | Unpinned or branch-pinned versions | Tags, `~>` constraints, committed lock file |
| 9 | Redundant `depends_on` | Attribute references; comment the real ones |
| 10 | `null_resource` glue | Real provider, or a pipeline step |
| 11 | `ignore_changes = all` | Ignore named attributes, with a reason |
| 12 | Deep nesting and pass-through sprawl | Flatten to two levels; compose at root |
| 13 | `dynamic` everywhere | Typed variables and separate rule resources |
| 14 | Env drift and ClickOps | Shared module versions + nightly drift detection |
