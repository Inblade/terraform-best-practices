# Terraform Best Practices

Personal working notes on Terraform, written down properly. This is the
guidance I have converged on after years of building and operating
infrastructure-as-code in production — the state layouts that survived a
migration, the module interfaces that did not need a major version bump every
quarter, and the specific mistakes that cost me a weekend. It is opinionated on
purpose: unqualified advice is easy to write and useless to apply, so where
there is a trade-off I have tried to name both sides and then say which one I
pick and why.

Everything here is written for **Terraform >= 1.9**, the era of `moved` /
`import` / `removed` blocks, cross-variable `validation` conditions,
provider-defined functions, and — from 1.10 and 1.11 — ephemeral values and
write-only arguments. Where a feature needs a newer version than 1.9, or behaves
differently on older Terraform or on OpenTofu, the document says so inline.

No employer's code, configuration or infrastructure appears here. The examples
are reconstructions written for this repository, and they are checked with
`terraform fmt` and `terraform validate`.

---

## Structure

```
terraform-best-practices/
├── README.md
├── LICENSE
├── .gitignore
├── docs/
│   ├── state-management.md      # backends, locking, isolation, surgery, DR
│   ├── module-design.md         # interfaces as contracts, versioning, layout
│   ├── testing.md               # the ladder: fmt -> validate -> lint -> test
│   ├── import-and-refactor.md   # moved/import/removed, splitting a monolith
│   └── anti-patterns.md         # 14 named failure modes, with fixes
└── examples/
    └── good-module/             # a small, valid, exemplary S3 bucket module
        ├── README.md
        ├── main.tf
        ├── variables.tf
        ├── outputs.tf
        └── versions.tf
```

## Contents

| Document | What it covers | Read it when |
|---|---|---|
| [`docs/state-management.md`](docs/state-management.md) | What state is for and that it holds secrets in plaintext; S3 (DynamoDB vs native `use_lockfile`), GCS, azurerm, HCP Terraform; what a lock actually protects and when `force-unlock` is dangerous; workspaces vs directory-per-env vs Terragrunt vs one giant state, compared with failure modes; plan-time and blast radius; `state list/show/mv/rm/pull/push/replace-provider`; drift detection with `-detailed-exitcode`; rolling back a state version | You are starting a repo, or something has gone wrong with state |
| [`docs/module-design.md`](docs/module-design.md) | The interface is the contract; typed variables and `validation` blocks; output design; **when not to write a module**; composition over configuration; why providers belong to the root; semver rules for modules and what counts as breaking; pinning with `~>` and `?ref=v3.2.1`; repo layout and terraform-docs | You are about to write or review a module |
| [`docs/testing.md`](docs/testing.md) | The ladder from `fmt` to Terratest, with a table of what each rung catches, what it cannot, and roughly what it costs; a real `.tflint.hcl`; Checkov/Trivy against plan JSON; OPA/Conftest policy; native `terraform test` with `command = plan` and `command = apply`; Terratest patterns; a full GitHub Actions workflow; cleanup and budget | You want a CI pipeline that catches things before production does |
| [`docs/import-and-refactor.md`](docs/import-and-refactor.md) | `moved` blocks including `count` -> `for_each`; `import` blocks and the limits of `-generate-config-out`; `removed` blocks with `lifecycle { destroy = false }`; a step-by-step recipe for splitting a monolith state with an acceptance gate and rollback at every step; the gotchas (`default_tags` drift, `name_prefix`, data sources, dependencies crossing the seam); `state replace-provider` | You need to rename, move, adopt or split something that already exists |
| [`docs/anti-patterns.md`](docs/anti-patterns.md) | Fourteen named failure modes — `count` over named things, `for_each` over unknown values, hardcoded environments, the giant root module, workspaces-as-environments, routine `-target`, secrets in tfvars, unpinned versions, `depends_on` abuse, `null_resource` glue, `ignore_changes = all`, nesting sprawl, `dynamic` everywhere, environment drift and ClickOps — each with symptom, cost and a code-pair fix | Reviewing someone else's Terraform, or wondering why yours hurts |
| [`examples/good-module/`](examples/good-module/) | A small S3 bucket module in current AWS provider style (separate versioning / encryption / public-access-block / lifecycle resources), two `validation` blocks, typed inputs with `optional()`, described outputs, no provider block, and a hand-written terraform-docs-style README | You want a concrete reference for what the module-design doc is describing |

## How to use this

Read [`docs/anti-patterns.md`](docs/anti-patterns.md) first. It is the shortest
path to a diagnosis if something already hurts, and it links out to the longer
documents for the fixes.

Otherwise, the useful order is:

1. **[State management](docs/state-management.md)** — the decisions that are
   hardest to reverse. Get the backend, the locking and the isolation strategy
   right before writing much else.
2. **[Module design](docs/module-design.md)** — read the "when *not* to write a
   module" section before the rest of it.
3. **[Testing](docs/testing.md)** — wire the cheap rungs into CI on day one;
   they cost seconds and catch most PR defects.
4. **[Import and refactor](docs/import-and-refactor.md)** — reference material
   for the day you need it, which will come.

The example module is meant to be read, not consumed. It validates cleanly, but
it deliberately omits bucket policies, replication, notifications and logging —
adding them would make it a worse teaching example and it would still be worse
than the community modules. Point your `source` at
`terraform-aws-modules/s3-bucket/aws` for real work.

To check the example yourself:

```bash
cd examples/good-module
terraform init -backend=false
terraform fmt -check -recursive
terraform validate
```

Nothing in this repository applies anything or costs money on its own. There is
no root module with a backend, and the example has no provider configuration.

## Opinions, not law

These are conclusions from a particular set of environments — mostly AWS and
GCP, mostly Kubernetes-adjacent platform work, mostly teams between three and
thirty engineers, mostly regulated enough that audit trails mattered. Your
constraints are different, and some of these recommendations invert under
different ones.

Specifically:

- **"Directory per environment" is my default, not a universal truth.** If you
  run forty near-identical tenant stacks, workspaces or Terragrunt genuinely win
  and my objections stop applying.
- **"Do not write a module for fewer than three consumers" is a heuristic against
  premature abstraction**, not a rule. If you know a fourth is coming next
  month, write it.
- **The testing budget in `testing.md` assumes cloud spend is a real constraint.**
  If it is not, integration-test more. If your infrastructure is genuinely
  simple, integration-test less than I suggest.
- **The split-the-state advice assumes a team.** A solo operator with 200
  resources should not build four root modules and a remote-state graph.
- **Terraform version gating moves fast.** Everything here was accurate against
  the 1.9-1.13 line. Check the changelog before assuming a feature exists.
- **OpenTofu is not a drop-in for every claim here.** Backends and state format
  are compatible; testing mocks, the `cloud` block, ephemeral values and state
  encryption are not. Where it matters I have flagged it, but do not treat the
  flags as exhaustive.

Where I have been burned by a pattern, I say so and describe the failure rather
than asserting a rule. Where something is a matter of taste — file naming,
whether locals go in `locals.tf` — I have tried not to have an opinion at all.
If a recommendation here does not survive contact with your constraints, the
recommendation is wrong for you, and the reasoning is the part worth keeping.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 Danylo Kochetov.
