# Testing Terraform

Terraform testing is a ladder. Each rung costs more time and money than the one
below and catches a class of bug the ones below cannot. The mistake teams make
is skipping the cheap rungs (which run in seconds and catch the majority of real
PR defects) and then also skipping the expensive ones (because nobody budgeted
for them), leaving `terraform plan` in a PR comment as the only gate.

Rough guidance: **run rungs 1-5 on every PR, rung 6 on every module change, rung
7 nightly on the two or three modules where a regression would be an outage.**

---

## 1. The ladder

| # | Tool / command | Catches | Cannot catch | Needs creds | Typical runtime |
|---|---|---|---|---|---|
| 1 | `terraform fmt -check -recursive` | Formatting, inconsistent indentation | Anything semantic | No | < 1 s |
| 2 | `terraform validate` | Syntax errors, unknown attributes, type mismatches, undeclared variables, bad references, invalid function calls | Whether values are legal to the API; anything requiring variable values; anything about existing infrastructure | No (needs `init`, which needs registry access) | 2-10 s |
| 3 | `tflint` + provider plugin | Deprecated syntax, invalid instance types, AMIs that do not exist in the region, unused declarations, naming conventions, missing `required_version` | Runtime/API behaviour, cross-resource security posture, cost | No (plugin metadata only) | 3-20 s |
| 4 | Checkov / Trivy / Terrascan | Misconfiguration and security policy: public buckets, unencrypted volumes, `0.0.0.0/0` ingress, IAM wildcards, missing logging | Logic bugs; whether the config applies cleanly; org-specific rules not in the ruleset | No (config scan); yes for plan-JSON scan | 10-60 s |
| 5 | OPA/Conftest or Sentinel on plan JSON | Organisation policy against the **actual planned change**: forbidden instance families, mandatory tags, no destroys of stateful resources, region allowlists | Anything not expressible over the plan; provider bugs | Yes (a plan requires credentials) | 5-30 s + plan time |
| 6 | `terraform test` (`.tftest.hcl`) | Module logic: does variable X produce attribute Y; do validations reject bad input; do outputs wire correctly. `command = apply` additionally proves it really applies | Whatever the provider does not model; long-horizon behaviour; anything cross-account you have not fixtured | `plan` runs need provider auth for data sources; `apply` runs need full creds | 5 s (plan) to minutes (apply) |
| 7 | Terratest (Go) | End-to-end reality: does the ALB return 200, does the DB accept a connection, does the node join the cluster, does the failover work | Nothing much — but it is slow, expensive and flaky if written carelessly | Yes, and a real spend budget | 5-45 min per suite |

Two things people get wrong about rung 2: `terraform validate` **does require
`terraform init`** (it needs provider schemas), and it **does not** evaluate
variable values — a `validation` block never fires during `validate`, because no
values are supplied. Validation blocks fire at `plan`.

---

## 2. Rungs 1-2: fmt and validate

```bash
# Fail the build on unformatted files, recursively, showing the diff.
terraform fmt -check -recursive -diff

# Validate every directory containing .tf files, without touching a backend.
find . -type f -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; \
  | sort -u \
  | while read -r dir; do
      echo "== $dir"
      terraform -chdir="$dir" init -backend=false -input=false -no-color >/dev/null || exit 1
      terraform -chdir="$dir" validate -no-color || exit 1
    done
```

`-backend=false` is what makes this usable in CI without credentials or backend
access. It still downloads providers, so cache `.terraform` between runs or
`TF_PLUGIN_CACHE_DIR` it.

Cheap, fast, and it catches a genuinely large share of PR defects — typos in
attribute names, a `for_each` over the wrong type, a reference to a resource
someone deleted.

---

## 3. Rung 3: tflint

`terraform validate` knows the provider *schema*. tflint knows provider
*semantics* — that `t2.mega` is not a real instance type, that this AMI ID does
not exist in `eu-west-1`, that `aws_alb` is a deprecated alias.

A real `.tflint.hcl`:

```hcl
plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.42.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"

  # "deep check" calls the AWS API to verify that referenced resources exist.
  # It is genuinely useful and genuinely needs read-only credentials.
  deep_check = false
}

config {
  call_module_type = "local"
  force            = false
}

# Every variable must be typed and described.
rule "terraform_typed_variables" {
  enabled = true
}

rule "terraform_documented_variables" {
  enabled = true
}

rule "terraform_documented_outputs" {
  enabled = true
}

# Catch dead code.
rule "terraform_unused_declarations" {
  enabled = true
}

# Modules and providers must be version-constrained.
rule "terraform_module_version" {
  enabled = true
  exact   = false
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

# Enforce snake_case resource and variable names.
rule "terraform_naming_convention" {
  enabled = true
  format  = "snake_case"
}

# Comment style and file layout.
rule "terraform_comment_syntax" {
  enabled = true
}

# AWS-specific: reject instance types that do not exist.
rule "aws_instance_invalid_type" {
  enabled = true
}
```

```bash
tflint --init                       # download plugins, honours .tflint.hcl
tflint --recursive --format=compact
tflint --recursive --format=sarif > tflint.sarif   # for GitHub code scanning
```

`call_module_type = "local"` (older tflint: `module = true`) makes tflint descend
into local modules. Note that older tflint versions used `module = true`; the
option was renamed, so pin the tflint version in CI.

---

## 4. Rung 4: static security scanning

Three tools, overlapping rulesets, different opinions.

| Tool | Notes |
|---|---|
| **Checkov** | Largest ruleset, Python, good custom-policy story (Python or YAML), scans plan JSON and many other IaC formats. Noisiest by default. |
| **tfsec** | Merged into **Trivy**; `tfsec` itself is in maintenance mode. Use `trivy config`. Fast, Go, fewer false positives, weaker custom policies. |
| **Terrascan** | Rego-based, smaller community. Reasonable if you are already invested in OPA. |

Pick one and tune it. Running all three produces three overlapping backlogs and
teaches the team to ignore scanner output, which is worse than running none.

```bash
# Scan HCL directly.
checkov -d . --framework terraform --compact --quiet

# Scan the actual planned change - fewer false positives, because it sees
# resolved variable values and module composition rather than raw HCL.
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
checkov -f plan.json --framework terraform_plan --compact

# Trivy equivalent.
trivy config --severity HIGH,CRITICAL --exit-code 1 .
```

Scanning **plan JSON** rather than HCL is the important upgrade. A module that
takes `var.acl` cannot be judged from HCL; the plan knows the caller passed
`public-read`.

Suppressions belong in code, next to the thing being suppressed, with a reason:

```hcl
# checkov:skip=CKV_AWS_18:Access logging targets a bucket in the log archive
# account, configured out-of-band by the landing-zone pipeline.
resource "aws_s3_bucket" "artifacts" {
  bucket = var.bucket_name
}
```

A baseline file (`checkov --create-baseline`) is acceptable for adopting a
scanner on a large existing codebase. It is not acceptable as a permanent
parking lot; put an expiry date on it.

---

## 5. Rung 5: policy as code on the plan

Scanners encode generic best practice. Policy engines encode **your** rules:
"nothing outside eu-west-1", "no `db.*.metal`", "every resource carries a
`cost-center` tag", "no plan may destroy an RDS instance without an approval
label".

Conftest / OPA against plan JSON:

```rego
# policy/terraform.rego
package main

import rego.v1

deny contains msg if {
    resource := input.resource_changes[_]
    resource.change.actions[_] == "delete"
    startswith(resource.type, "aws_db_")
    msg := sprintf("refusing to destroy stateful resource %s", [resource.address])
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.change.actions[_] != "delete"
    resource.type == "aws_instance"
    not resource.change.after.tags["cost-center"]
    msg := sprintf("%s is missing the cost-center tag", [resource.address])
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.change.actions[_] != "delete"
    resource.type == "aws_instance"
    startswith(resource.change.after.instance_type, "p4d.")
    msg := sprintf("%s uses %s; GPU instances require an approved exception", [resource.address, resource.change.after.instance_type])
}
```

```bash
terraform plan -out=plan.tfplan
terraform show -json plan.tfplan > plan.json
conftest test --policy policy/ plan.json
```

Sentinel is the equivalent inside HCP Terraform, with the advantage of enforcement
levels (`advisory`, `soft-mandatory`, `hard-mandatory`) and native integration
into the run workflow. The trade-off is that it only runs there.

**Gotcha:** `change.after` is `null` for destroys, and unknown-at-plan values
appear in `after_unknown`, not `after`. Policies that naively read `after` will
either crash or pass vacuously on exactly the changes you care about. Write
tests for your policies.

---

## 6. Rung 6: `terraform test`

Native testing landed in Terraform **1.6** and is the right default for module
tests today. Files are `*.tftest.hcl`, live in `tests/` (or next to the module),
and run with `terraform test`.

The key distinction:

- `command = plan` — a **unit test**. Fast, creates nothing, and can assert on
  planned attribute values and on `expect_failures` for validation blocks.
- `command = apply` (the default) — an **integration test**. Creates real
  infrastructure and destroys it afterwards, including on failure.

The unit tests below run against `examples/good-module` in this repository, with
no credentials and no network access — `cd examples/good-module && terraform test`
works on a laptop or in CI:

```hcl
# examples/good-module/tests/defaults.tftest.hcl

# mock_provider (Terraform 1.7+) fakes every AWS API response, so `command = plan`
# runs need no credentials at all. The trade-off is that you are asserting
# against your own module's logic, not against what AWS would really accept.
mock_provider "aws" {}

variables {
  bucket_name = "acme-tftest-defaults"
}

# --- Unit: secure defaults are actually secure ------------------------------

run "encryption_defaults_to_sse_s3" {
  command = plan

  # `rule` is a SET, not a list, so `rule[0]` is a hard error: "Block type
  # rule is represented by a set of objects, and set elements do not have
  # addressable keys." Use one() on a for expression instead - it also asserts
  # that exactly one rule exists.
  assert {
    condition = one([for r in aws_s3_bucket_server_side_encryption_configuration.this.rule :
      one(r.apply_server_side_encryption_by_default).sse_algorithm
    ]) == "AES256"
    error_message = "Expected SSE-S3 when no KMS key is supplied."
  }

  assert {
    condition     = output.sse_algorithm == "AES256"
    error_message = "sse_algorithm output does not match the configured algorithm."
  }
}

run "public_access_is_blocked_on_all_four_flags" {
  command = plan

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.this.block_public_acls,
      aws_s3_bucket_public_access_block.this.block_public_policy,
      aws_s3_bucket_public_access_block.this.ignore_public_acls,
      aws_s3_bucket_public_access_block.this.restrict_public_buckets,
    ])
    error_message = "All four public access block flags must be true."
  }
}

run "kms_key_switches_algorithm_and_enables_bucket_keys" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:eu-west-1:111122223333:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition = one([for r in aws_s3_bucket_server_side_encryption_configuration.this.rule :
      r.bucket_key_enabled
    ])
    error_message = "Bucket keys must be enabled for SSE-KMS to control request cost."
  }
}

# --- Unit: validation blocks reject bad input -------------------------------

run "rejects_uppercase_bucket_name" {
  command = plan

  variables {
    bucket_name = "Acme-Bad-Name"
  }

  expect_failures = [var.bucket_name]
}

run "rejects_expiration_before_transition" {
  command = plan

  variables {
    lifecycle_rules = {
      broken = {
        transition_days = 90
        expiration_days = 30
      }
    }
  }

  expect_failures = [var.lifecycle_rules]
}
```

An integration test in the same suite. Note the unique suffix: S3 bucket names
are globally unique, so without one two concurrent CI runs collide and a leftover
bucket from a killed run blocks every future test.

`uuid()` in the top-level `variables` block is evaluated once per test file, which
keeps this self-contained — no setup module or fixture directory required. (A
`run "setup"` block calling a small helper module is the alternative, and is worth
it once several test files need to share the same generated values.)

There is no `mock_provider` here: an apply-test asserts that AWS really accepts
the configuration, so it needs genuine credentials.

```hcl
# examples/good-module/tests/integration.tftest.hcl

variables {
  bucket_name = "acme-tftest-${substr(uuid(), 0, 8)}"
}

run "creates_a_real_bucket" {
  command = apply

  variables {
    force_destroy = true

    lifecycle_rules = {
      expire-tmp = {
        prefix          = "tmp/"
        expiration_days = 7
      }
    }
  }

  assert {
    condition     = startswith(output.arn, "arn:aws:s3:::acme-tftest-")
    error_message = "ARN does not match the expected bucket name."
  }
}
```

```bash
cd examples/good-module

terraform init                       # test files still need the providers installed
terraform test                       # run everything in tests/
terraform test -filter=tests/defaults.tftest.hcl   # mocked, no credentials needed
terraform test -verbose              # show the plan/state for each run block
```

`tests/defaults.tftest.hcl` passes offline. `tests/integration.tftest.hcl` really
applies, so it needs credentials and will create and destroy an S3 bucket.

Notes and limits:

- **`force_destroy = true` in every apply-test.** Otherwise the teardown fails
  on a non-empty bucket and you leak resources into the account.
- Terraform destroys apply-test resources at the end of the file, including on
  failure — but not if the process is killed. Budget for a nightly sweeper that
  deletes tagged test resources older than a day.
- `mock_provider` (Terraform 1.7+) lets `plan` tests run without credentials at
  all, by faking provider responses. Very useful for pure-logic modules; it also
  means you are asserting against your mock, not AWS.
- **OpenTofu** implements `.tftest.hcl` from 1.6 with broadly compatible syntax,
  but mocking and some newer options diverge. Do not assume a test suite runs
  unchanged on both.

---

## 7. Rung 7: Terratest

Terratest is Go. That is a cost (someone must maintain Go code) and a benefit
(you can assert anything you can write, over HTTP, SSH, the AWS SDK, kubectl).

Use it when the assertion is about **behaviour of the running system**, not the
shape of the config. "The ALB serves 200 on /healthz through the WAF" is a
Terratest assertion. "The bucket is encrypted" is a `terraform test` assertion.

```go
package test

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/gruntwork-io/terratest/modules/http-helper"
	"github.com/gruntwork-io/terratest/modules/random"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
)

func TestServiceServesTraffic(t *testing.T) {
	t.Parallel()

	// Random suffix prevents collisions between parallel runs and between
	// this run and any leaked resources from a previous failed run.
	suffix := strings.ToLower(random.UniqueId())

	opts := &terraform.Options{
		TerraformDir: "../examples/service",
		Vars: map[string]interface{}{
			"name":   fmt.Sprintf("tt-%s", suffix),
			"region": "eu-west-1",
		},
		EnvVars: map[string]string{
			"AWS_DEFAULT_REGION": "eu-west-1",
		},
		// Retry on the eventual-consistency errors that make cloud tests flaky.
		RetryableTerraformErrors: map[string]string{
			".*RequestError: send request failed.*": "transient AWS API error",
			".*timeout while waiting for state.*":   "slow resource creation",
		},
		MaxRetries:         3,
		TimeBetweenRetries: 10 * time.Second,
	}

	// Deferred FIRST, so a panic during Apply still tears down.
	defer terraform.Destroy(t, opts)

	terraform.InitAndApply(t, opts)

	url := fmt.Sprintf("https://%s/healthz", terraform.Output(t, opts, "endpoint"))
	http_helper.HttpGetWithRetry(t, url, nil, 200, "ok", 30, 10*time.Second)

	assert.Equal(t, "prod", terraform.Output(t, opts, "environment"))
}
```

Practical rules:

- `defer terraform.Destroy` goes **immediately after building options and before
  `InitAndApply`**, so a failure inside apply still tears down what was created.
- Everything gets a random suffix. Global namespaces (S3 buckets, IAM roles,
  Route53 records) collide otherwise, and a collision looks like a code bug.
- Tag every test resource (`Terratest = "true"`, `TTL = <timestamp>`) and run a
  sweeper. Tests **will** leak: runners get evicted, Go panics, AWS throttles.
- Run in a **dedicated test account** with a budget alarm and, ideally, an SCP
  denying expensive instance families.
- These are slow. A suite that takes 25 minutes will not run on every PR, and
  should not; run it nightly and on merges to main.

---

## 8. CI wiring

```yaml
# .github/workflows/terraform-ci.yml
name: terraform-ci

on:
  pull_request:
    paths: ["**.tf", "**.tftest.hcl", ".github/workflows/terraform-ci.yml"]

permissions:
  contents: read
  pull-requests: write
  id-token: write

env:
  TF_VERSION: "1.13.3"
  TF_IN_AUTOMATION: "true"
  TF_PLUGIN_CACHE_DIR: /home/runner/.terraform.d/plugin-cache

jobs:
  static:
    name: fmt / validate / lint / scan
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Cache providers
        uses: actions/cache@v4
        with:
          path: ${{ env.TF_PLUGIN_CACHE_DIR }}
          key: tf-plugins-${{ hashFiles('**/.terraform.lock.hcl') }}

      - name: fmt
        run: terraform fmt -check -recursive -diff

      - name: validate
        run: |
          mkdir -p "$TF_PLUGIN_CACHE_DIR"
          find . -name '*.tf' -not -path '*/.terraform/*' -exec dirname {} \; \
            | sort -u | while read -r d; do
                terraform -chdir="$d" init -backend=false -input=false -no-color > /dev/null
                terraform -chdir="$d" validate -no-color
              done

      - uses: terraform-linters/setup-tflint@v4
        with:
          tflint_version: v0.53.0

      - name: tflint
        run: |
          tflint --init
          tflint --recursive --format=compact

      - name: checkov
        uses: bridgecrewio/checkov-action@v12
        with:
          directory: .
          framework: terraform
          quiet: true
          output_format: cli,sarif
          output_file_path: console,checkov.sarif
          soft_fail: false

      - uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: checkov.sarif

  unit-test:
    name: terraform test (plan only)
    runs-on: ubuntu-latest
    needs: static
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}
      - name: Run module tests
        working-directory: examples/good-module
        run: |
          terraform init -backend=false -input=false
          terraform test -no-color

  plan:
    name: plan (${{ matrix.env }})
    runs-on: ubuntu-latest
    needs: static
    strategy:
      fail-fast: false
      matrix:
        env: [staging, prod]
    steps:
      - uses: actions/checkout@v4

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::111122223333:role/terraform-plan-${{ matrix.env }}
          aws-region: eu-west-1

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}
          terraform_wrapper: false

      - name: Plan
        working-directory: envs/${{ matrix.env }}
        run: |
          terraform init -input=false
          terraform plan -input=false -lock-timeout=5m -out=tfplan
          terraform show -json tfplan > tfplan.json
          terraform show -no-color tfplan > tfplan.txt

      - name: Policy check
        working-directory: envs/${{ matrix.env }}
        run: conftest test --policy ../../policy tfplan.json

      # The binary plan is the artifact that `apply` must consume, so that what
      # was reviewed is exactly what is applied. It may contain secrets, so keep
      # retention short and the repo private.
      - uses: actions/upload-artifact@v4
        with:
          name: tfplan-${{ matrix.env }}
          path: |
            envs/${{ matrix.env }}/tfplan
            envs/${{ matrix.env }}/tfplan.txt
          retention-days: 5

      - name: Comment plan on PR
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            let body = fs.readFileSync('envs/${{ matrix.env }}/tfplan.txt', 'utf8');
            if (body.length > 60000) body = body.slice(0, 60000) + '\n... truncated, see artifact ...';
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `### Plan: ${{ matrix.env }}\n\n<details><summary>Show</summary>\n\n\`\`\`hcl\n${body}\n\`\`\`\n\n</details>`
            });
```

Points worth copying:

- **OIDC, not long-lived keys** (`id-token: write` + `configure-aws-credentials`).
- **The plan role is read-only.** Apply runs in a separate, protected workflow
  on merge, consuming the uploaded plan file.
- **The saved plan is the artifact of record.** Applying a re-planned change is
  applying something nobody reviewed.
- `terraform_wrapper: false` in the plan job, or the wrapper mangles exit codes
  and `-detailed-exitcode` becomes useless.
- Plan output can contain sensitive values. Short retention, private repo, and
  do not paste plans into public issues.

---

## 9. Test data, cleanup and budget

**Naming.** Every test resource gets a random suffix and a common prefix
(`tftest-`). The prefix makes sweeping possible; the suffix makes parallelism
possible.

**Sweeping.** Assume leaks. A nightly job that deletes anything tagged
`Terratest=true` or named `tftest-*` older than 24 hours is not optional once
you have integration tests. Terratest ships `aws.NewSweeper`-style helpers; a
20-line boto3 script also works.

**Isolation.** A dedicated test account per team, with a budget alarm at a
number that would embarrass you and an SCP denying the instance families that
generate surprise bills. Never run integration tests in an account that also
holds production.

**Budget.** A rough allocation that has worked for me:

| Layer | Coverage target | Cost |
|---|---|---|
| fmt/validate/tflint/checkov | 100% of code, every PR | Seconds. Free. |
| `terraform test` with `command = plan` | Every module: defaults, each validation block, each conditional branch | Seconds. Free. |
| `terraform test` with `command = apply` | Modules whose provider interaction is non-obvious (IAM, networking, anything with `depends_on`) | Minutes. Cents. |
| Terratest | The 2-4 modules whose failure is an outage: ingress, cluster, database | Tens of minutes. Dollars per run. Nightly. |

The asymmetry is deliberate. Cheap tests should be exhaustive; expensive tests
should be few and chosen for blast radius, not for coverage percentage.

**What none of this catches.** No test tells you whether the change is a good
idea, whether the capacity is right, or whether the rollout order is safe. Those
remain review problems. Testing raises the floor; it does not replace someone
who understands the system reading the plan.
