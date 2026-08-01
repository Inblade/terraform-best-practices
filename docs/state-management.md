# State Management

State is the part of Terraform that people understand last and get burned by
first. Almost every serious Terraform incident I have been involved in was a
state incident: a lock left behind, a state applied against the wrong account, a
`state rm` that deleted the wrong address, a bucket with no versioning after
someone pushed a truncated file.

This document covers what state actually is, how to store it, how to isolate it,
how to operate on it, and how to recover when it goes wrong.

---

## 1. What state is for

Terraform state is a JSON document that serves four distinct purposes. They are
worth separating because different backends and workflows trade them off
differently.

| Purpose | What it means | What breaks without it |
|---|---|---|
| **Mapping** | Binds a config address (`aws_instance.web[0]`) to a real remote object ID (`i-0abc123`) | Terraform cannot tell "create" from "already exists"; every apply tries to recreate everything |
| **Metadata** | Dependency graph as of last apply, provider config refs, schema version, `create_before_destroy` intent | Destroy ordering is wrong once you delete a resource from config; Terraform no longer knows what depended on what |
| **Performance** | Cached attribute values, so `plan` can skip API reads with `-refresh=false` | Every plan must refresh every resource; on 3000 resources that is minutes of API calls |
| **Concurrency** | The serial number and lineage that make locking meaningful | Two applies interleave and produce a state that describes neither reality nor the config |

And one property that is not a purpose but is a fact:

> **State contains secrets in plaintext.** RDS passwords, generated private keys,
> IAM access secrets, the contents of `aws_secretsmanager_secret_version`,
> Kubernetes secrets, anything a provider returned. `sensitive = true` only
> redacts CLI output. It changes nothing about what is written to the state file.

Design your access controls on the assumption that read access to state equals
read access to production credentials, because it does.

---

## 2. Remote backends

Local state is acceptable for a scratch directory and nothing else. It cannot be
locked across machines, it is not backed up, and it ends up in someone's laptop
backup or, worse, in git.

### S3 (with locking)

The canonical AWS setup. Note the version gating on locking:

- **Terraform < 1.10**: locking requires `dynamodb_table` pointing at a table
  with a string hash key named `LockID`.
- **Terraform >= 1.10 / OpenTofu >= 1.10**: `use_lockfile = true` enables native
  S3 conditional-write locking via a `.tflock` object next to the state. This
  supersedes DynamoDB. **Terraform 1.11 deprecated `dynamodb_table`**, and it is
  removed in the 1.12+ line.

Modern form:

```hcl
terraform {
  required_version = ">= 1.10"

  backend "s3" {
    bucket = "acme-tfstate-prod-euw1"
    key    = "platform/network/terraform.tfstate"
    region = "eu-west-1"

    # Native S3 locking. Replaces the DynamoDB table entirely.
    use_lockfile = true

    # Server-side encryption. kms_key_id implies SSE-KMS; without it you get
    # SSE-S3, which is better than nothing but not auditable per-key.
    encrypt    = true
    kms_key_id = "arn:aws:kms:eu-west-1:111122223333:key/8f0e...c31a"

    # Assume a per-environment role rather than relying on ambient credentials.
    # This is the single most effective guard against applying to prod by accident.
    assume_role = {
      role_arn     = "arn:aws:iam::111122223333:role/terraform-state-prod"
      session_name = "terraform"
    }

    # Refuse to write if the bucket has drifted to another account.
    expected_bucket_owner = "111122223333"
  }
}
```

If you are still on 1.9 or earlier, replace `use_lockfile = true` with:

```hcl
    dynamodb_table = "acme-tfstate-locks"
```

You can set both during a migration window; Terraform 1.10/1.11 will use both
and the lock is held in both places, which is exactly what you want while
rolling a fleet of root modules over.

**Bucket requirements, in order of importance:**

1. **Versioning enabled.** This is your only undo. Turn it on before the first
   `terraform init`, not after the incident.
2. **Bucket policy denying `s3:DeleteObjectVersion`** to everyone except a
   break-glass role. Versioning protects nothing if the same principal can
   delete versions.
3. **Public access block, all four flags**, and a policy with
   `"aws:SecureTransport": "false"` denied.
4. **SSE-KMS with a dedicated key**, and the key policy restricted to the
   Terraform roles. This gives you CloudTrail `Decrypt` events, meaning you can
   answer "who read prod state last month".
5. **Server access logging or CloudTrail data events** on the bucket. Reads of
   state are security-relevant events.
6. **A lifecycle rule expiring noncurrent versions after 90-180 days**, or the
   bucket grows without bound. Do not set this to 7 days; you will want old
   versions during an incident postmortem.
7. **The state bucket lives in its own root module** (or is created by hand
   once), because bootstrapping a bucket that stores its own state is a
   chicken-and-egg problem not worth the cleverness.

### GCS

```hcl
terraform {
  backend "gcs" {
    bucket = "acme-tfstate-prod"
    prefix = "platform/network"

    # Customer-managed encryption key; GCS is encrypted at rest regardless,
    # but CMEK gives you key-level revocation and audit.
    kms_encryption_key = "projects/acme/locations/eu/keyRings/tf/cryptoKeys/state"
  }
}
```

GCS locking is built in — it uses object generation preconditions, no side table.
Enable **object versioning** on the bucket for the same reason as S3.

### azurerm

```hcl
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate-prod"
    storage_account_name = "sttfstateprodweu"
    container_name       = "tfstate"
    key                  = "platform/network.tfstate"

    use_azuread_auth = true
    subscription_id  = "00000000-0000-0000-0000-000000000000"
  }
}
```

Locking uses native blob leases — again, no side table. Enable **blob versioning
and soft delete** on the storage account. Prefer `use_azuread_auth = true` over
storage account keys so that access is identity-based and revocable.

### Terraform Cloud / HCP Terraform

```hcl
terraform {
  cloud {
    organization = "acme"

    workspaces {
      tags = ["platform", "prod"]
    }
  }
}
```

You get state storage, locking, encryption, versioning with diffs, RBAC, run
history and remote execution for free. The trade-offs are real: you are handing
plaintext secrets to a vendor, remote execution changes how your CI works, and
cost scales with resources under management. It is often the right call for
small teams who would otherwise not build any of it, and the wrong call when you
have strict data residency constraints.

**OpenTofu note:** the `cloud` block does not apply. OpenTofu supports the same
S3/GCS/azurerm backends plus **client-side state encryption**, which Terraform
does not have — an `encryption` block in `terraform {}` that encrypts state and
plan files with a passphrase or KMS key before they reach the backend. If
plaintext secrets in state is your blocking concern, that feature alone is a
reason to evaluate OpenTofu.

---

## 3. Locking: what it does and does not do

A lock prevents **two Terraform operations from writing the same state
concurrently**. That is all. It does not:

- prevent someone changing infrastructure in the console,
- prevent a different root module from touching the same resources,
- prevent an apply from a stale plan,
- serialize anything at the AWS API level.

### What happens on a crash

If Terraform dies mid-apply — CI runner evicted, laptop lid closed, SIGKILL —
the lock stays held. The next run fails with:

```
Error: Error acquiring the state lock

Lock Info:
  ID:        4a2f9d1e-6b3c-4c8a-91f7-2d5e0a7b1c33
  Path:      acme-tfstate-prod-euw1/platform/network/terraform.tfstate
  Operation: OperationTypeApply
  Who:       runner@ip-10-0-3-14
  Created:   2026-07-28 09:14:22.118 +0000 UTC
```

Before you unlock, answer one question: **is the original process definitely
dead?** Check the CI job. If the job is still running, wait. Force-unlocking a
live apply lets a second apply run concurrently, and the loser's write silently
discards the winner's resource mappings — you get orphaned real resources that
Terraform no longer knows about.

If the process is genuinely dead:

```bash
terraform force-unlock 4a2f9d1e-6b3c-4c8a-91f7-2d5e0a7b1c33
```

Then, critically, **inspect what the dead apply actually did** before running
anything else. A crashed apply may have created resources whose IDs never made
it into state. `terraform plan` will propose creating them again, which for
anything with a unique name will fail, and for anything without one will
duplicate. Check the provider's console/API for orphans first.

---

## 4. State isolation strategies

This is the highest-leverage decision in a Terraform codebase, and it is very
expensive to change later.

| Strategy | How it works | Pros | Failure modes | Verdict |
|---|---|---|---|---|
| **Workspaces** | One backend config, one key prefix; `terraform workspace select prod` switches the state path | Zero duplication; instant to add an environment; good for ephemeral per-PR copies | Same backend config and **same credentials for every workspace** — nothing stops a prod apply from a dev shell; the selected workspace is invisible ambient state, so `terraform apply` after forgetting to switch is a real and common outage; no per-env provider config, region or account; conditionals like `count = terraform.workspace == "prod" ? 3 : 1` metastasize; all workspaces share one lock namespace per key | Good for ephemeral/identical copies. **Bad for prod-vs-dev.** |
| **Directory per environment** | `envs/prod/`, `envs/staging/`, each a root module with its own backend block and provider config, calling shared modules | Explicit and greppable; per-env backend, credentials, provider version, region and IAM permissions; env differences are visible in code review, not hidden in conditionals; blast radius bounded by directory; CI can restrict who plans/applies which path | Duplication of backend and provider boilerplate; environments drift when someone updates prod and forgets staging; needs discipline plus a CI check that all envs plan clean | **Best default.** The duplication is a feature: it is the diff that shows how prod differs. |
| **Terragrunt or an in-house wrapper** | Generates backend/provider blocks from a hierarchy of config files; `run-all` across stacks | Removes the duplication of directory-per-env while keeping isolation; dependency graph across states; good at 20+ stacks | Another tool, another version to pin, another DSL for new hires; error messages get one layer further from Terraform's; `run-all apply` re-creates the giant-blast-radius problem you split states to avoid; couples you to the wrapper's release cadence | Worth it past roughly 10-15 root modules. Premature below that. |
| **One giant state** | Everything in one root module | Trivially simple; every cross-resource reference is a direct attribute reference, no remote state lookups | Plans take 10-30 minutes; every change locks everything, so the team serializes on one lock; one bad `apply` can destroy unrelated production; refresh alone hits API rate limits; `state rm` accidents are catastrophic; nobody dares run it | Only for genuinely small footprints. Split before you feel the pain, not after. |

### A workable default

```
envs/
  prod/
    network/      # VPC, subnets, TGW attachments  - changes monthly
    data/         # RDS, ElastiCache               - changes rarely, high risk
    platform/     # EKS, node groups, addons       - changes weekly
    apps/         # ALBs, ECS services, DNS        - changes daily
  staging/
    ...
modules/
  vpc/
  eks-cluster/
  s3-bucket/
```

The seams follow **rate of change and blast radius**, not org chart or AWS
service category. A change to `apps/` should never be able to touch the VPC. The
`data/` state is applied by a different role than the `apps/` state.

---

## 5. Blast radius and plan time

State size drives plan time almost linearly, because refresh is one or more API
calls per resource, mostly serialized within a dependency chain.

Rough field numbers, AWS, default `-parallelism=10`:

| Resources in state | Refresh + plan wall time |
|---|---|
| ~50 | 10-20 s |
| ~500 | 1-3 min |
| ~3000 | 8-20 min, with intermittent API throttling |

At 3000 resources the feedback loop is dead. People stop running plans, start
guessing, and reach for the escape hatches:

```bash
# Skip refresh. Plan against cached state. Fast, and WRONG if anything drifted.
terraform plan -refresh=false

# Plan/apply a subset of the graph.
terraform apply -target=module.app.aws_ecs_service.api
```

`-refresh=false` is legitimate for a quick iteration on config syntax when you
just refreshed. It is not legitimate as the standard plan in CI, because the
whole point of CI plan is to catch drift.

`-target` is an emergency tool. Terraform itself prints a warning saying so. It
produces a partial apply, so the resulting state can be internally inconsistent
with the config; the next full plan may surface a surprise. Legitimate uses:
unblocking a broken apply, working around a provider bug, recovering from a
crashed apply. Illegitimate use: making a slow root module tolerable. If you
find yourself typing `-target` weekly, **the real fix is splitting the state**
(see [`import-and-refactor.md`](import-and-refactor.md)).

---

## 6. State operations

### Inspect first, always

```bash
# Every managed address in state.
terraform state list

# Filtered to a module.
terraform state list 'module.platform.*'

# Full attributes of one resource, including sensitive values.
terraform state show aws_db_instance.main

# The raw state document. Pipe to a file BEFORE any surgery.
terraform state pull > backup-$(date +%Y%m%dT%H%M%S).json
```

`terraform state pull` is the first command of every state operation. Not
optional. It costs two seconds and it is the difference between a five-minute
mistake and a five-hour one.

### Move and remove

```bash
# Rename an address, or move it into a module. Prefer a `moved` block in code.
terraform state mv aws_instance.web module.frontend.aws_instance.web

# Move from a list to a map after switching count -> for_each.
terraform state mv 'aws_instance.web[0]' 'aws_instance.web["a"]'

# Forget a resource WITHOUT destroying it. Prefer a `removed` block (TF >= 1.7).
terraform state rm aws_iam_role.legacy

# Cross-state move (both must be local files or use -state / -state-out).
terraform state mv -state=old.tfstate -state-out=new.tfstate \
  aws_s3_bucket.logs aws_s3_bucket.logs
```

For anything you would do with `state mv` or `state rm` in a codebase under
review, **use `moved` and `removed` blocks instead**. They are declarative,
reviewable in the PR, idempotent, and they work in CI where nobody is at a
terminal. The CLI commands remain useful for one-off surgery and for cross-state
moves.

### Provider replacement

When a provider moves in the registry — a namespace change, a fork, or migrating
to OpenTofu's registry — every resource in state carries the old provider FQN
and Terraform refuses to plan:

```bash
# See what's referenced.
terraform providers

# Rewrite the provider for every matching resource in state.
terraform state replace-provider \
  registry.terraform.io/-/aws \
  registry.terraform.io/hashicorp/aws

# Community provider that changed namespace.
terraform state replace-provider \
  registry.terraform.io/mongey/kafka \
  registry.terraform.io/Mongey/kafka
```

The `registry.terraform.io/-/name` form is the legacy pre-0.13 shape and shows
up in states with very long histories. This command edits state only; you still
need the matching `required_providers` change in code.

### Splitting a state safely

The safe order matters. The unsafe order — `state rm` first, then import —
leaves a window where the resource is managed by nobody, and if the import fails
you have real infrastructure and no state entry.

```bash
# 1. Back up. Twice.
cd envs/prod/monolith
terraform state pull > /secure/monolith-$(date +%s).json

# 2. Inventory and pick the seam.
terraform state list | grep '^module\.data\.' > /tmp/moving.txt
wc -l /tmp/moving.txt

# 3. Build the new root module: config, backend, provider, variables.
#    Populate it using `import` blocks - see import-and-refactor.md.
cd ../data
terraform init
terraform plan -out=verify.tfplan

# 4. ACCEPTANCE GATE: the new root must plan to ZERO changes.
#    Not "only tag changes". Zero.
terraform show -json verify.tfplan \
  | jq '[.resource_changes[] | select(.change.actions != ["no-op"])] | length'
# -> must print 0

# 5. Only now drop them from the old root, via `removed` blocks in code.
cd ../monolith
terraform plan   # must show only the removals, no destroys
terraform apply
```

Rollback at each step: before step 5 you can simply delete the new root's state
and nothing has changed. After step 5, restore the backup from step 1 with
`terraform state push`.

### Rolling back a state version

```bash
# S3: list versions of the state object.
aws s3api list-object-versions \
  --bucket acme-tfstate-prod-euw1 \
  --prefix platform/network/terraform.tfstate \
  --query 'Versions[].{V:VersionId,T:LastModified,S:Size}' --output table

# Fetch the known-good one.
aws s3api get-object \
  --bucket acme-tfstate-prod-euw1 \
  --key platform/network/terraform.tfstate \
  --version-id 3sL0nBz9xQ.7f1kR2mYcVpN4dW6eT8u \
  restored.tfstate

# Push it back. Terraform refuses if the serial is lower, hence -force.
terraform state push -force restored.tfstate

# Then immediately verify against reality.
terraform plan
```

`-force` bypasses the lineage and serial checks that exist to stop exactly this
kind of write. Use it only when you have consciously decided the current state
is wrong, and only after taking a copy of the current state too — you may need
to merge, not replace.

---

## 7. Drift detection

Drift is inevitable: console changes, autoscaling, another tool's controller,
manual incident surgery. Detect it on a schedule rather than discovering it
during an urgent deploy.

`terraform plan -detailed-exitcode` gives three exit codes:

| Code | Meaning |
|---|---|
| `0` | No changes. Infrastructure matches config. |
| `1` | Error. |
| `2` | Changes present — drift or unapplied config. |

```yaml
# .github/workflows/drift.yml
name: drift-detection
on:
  schedule:
    - cron: "0 6 * * 1-5"
  workflow_dispatch:

permissions:
  id-token: write
  contents: read
  issues: write

jobs:
  detect:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        stack: [network, data, platform, apps]
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::111122223333:role/terraform-plan-readonly
          aws-region: eu-west-1
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.13.3
      - name: Plan
        id: plan
        working-directory: envs/prod/${{ matrix.stack }}
        run: |
          terraform init -input=false
          set +e
          terraform plan -input=false -lock=false -detailed-exitcode -no-color -out=drift.tfplan
          echo "exitcode=$?" >> "$GITHUB_OUTPUT"
      - name: Report drift
        if: steps.plan.outputs.exitcode == '2'
        working-directory: envs/prod/${{ matrix.stack }}
        run: |
          terraform show -no-color drift.tfplan > drift.txt
          gh issue create \
            --title "Drift detected in prod/${{ matrix.stack }}" \
            --body-file drift.txt
        env:
          GH_TOKEN: ${{ github.token }}
```

Two details that matter: the role is **read-only**, and the plan runs with
`-lock=false` so a scheduled drift check can never block a human's apply. A
read-only role means the worst case for a compromised scheduled job is
information disclosure — which, given state contents, is still bad, so scope the
role tightly.

---

## 8. Secrets in state

Restating, because it is the thing people get wrong: **you cannot make state not
contain secrets.** Every mitigation is about limiting who can read it.

What actually helps:

1. **Encrypt at rest with a customer-managed key** and audit `Decrypt` calls.
2. **Least privilege on the state bucket.** Read access to prod state should be
   as tightly held as read access to the secrets manager, because it is
   equivalent.
3. **Do not generate secrets in Terraform.** `random_password` writes the
   password to state forever. Prefer having the secrets manager generate it
   (`aws_secretsmanager_secret` with a rotation lambda, or a manually seeded
   secret) and have Terraform reference the ARN, never the value.
4. **Ephemeral resources and write-only arguments (Terraform 1.10+ / 1.11+).**
   `ephemeral` resources and `ephemeral` variables (1.10) are never persisted to
   state or plan files. **Write-only arguments** (1.11) let you pass a value to a
   provider — e.g. `password_wo` on `aws_db_instance` — without it being stored.
   This is the first genuine fix for the plaintext-secret problem rather than a
   mitigation. Coverage is per-resource and still expanding; check the provider
   docs for `_wo` arguments.

   ```hcl
   ephemeral "aws_secretsmanager_secret_version" "db" {
     secret_id = aws_secretsmanager_secret.db.id
   }

   resource "aws_db_instance" "main" {
     # ...
     password_wo         = ephemeral.aws_secretsmanager_secret_version.db.secret_string
     password_wo_version = 1
   }
   ```

   OpenTofu's equivalent story is different: it has client-side state encryption
   from 1.7 and its own ephemeral-values work. Do not assume feature parity.
5. **Never commit state.** Add `*.tfstate*` to `.gitignore` on day one. If state
   has ever been committed, the secrets in it are compromised — rotate them,
   rewriting git history is not sufficient because the repo has been cloned.

---

## 9. Disaster recovery checklist

Things to have in place *before* you need them:

- [ ] Bucket versioning on, verified by actually listing versions.
- [ ] Deletion of object versions denied except to a break-glass role.
- [ ] Backend bucket in a separate account from the workloads it describes.
- [ ] A documented, tested procedure for `state push -force` rollback.
- [ ] Lock table / lockfile monitored — a lock older than the longest legitimate
      apply is an alert, not something someone notices next Tuesday.
- [ ] CI applies with a role that cannot delete the state bucket.
- [ ] Scheduled drift detection wired to an alert someone reads.
- [ ] `terraform state pull` snapshot taken before any manual state surgery,
      stored somewhere that is not the machine doing the surgery.

If state is genuinely lost and unrecoverable, the path back is import, not
recreate: build the config to match reality, then use `import` blocks to
reattach every resource. Budget days, not hours, for anything non-trivial. This
is the strongest possible argument for versioning the bucket.
