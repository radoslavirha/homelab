---
name: sync-docs
description: "Update and sync all repository documentation after any change. Use when: adding a cluster, adding an app, changing a version, adding a Terraform module, changing directory structure, modifying a bootstrap sequence, after terraform apply, after ArgoCD manifest changes, updating helm values, renaming resources, changing machine specs, adding stages, or any other repository change that may make docs stale. Keeps README.md, AGENTS.md, docs/architecture.md, and docs/iac.md perfectly in sync with the actual codebase."
argument-hint: "Describe what changed, e.g. 'added server4 cluster' or 'bumped Cilium to 1.17'"
---

# sync-docs

Scans all documentation files after a repository change and updates every stale reference so docs always match the codebase.

## When to Use

Load this skill after **any** of the following:
- Adding or removing a cluster
- Adding, renaming, or removing an ArgoCD app or manifest
- Adding or removing a Terraform module or stage
- Bumping a component version (Talos, Kubernetes, Cilium, Longhorn, Gateway API, ArgoCD, OpenBao)
- Changing directory structure anywhere in `iac/` or `gitops/`
- Modifying a bootstrap sequence or operational command
- Changing machine hardware specs
- Any other change that might make a doc section stale

## Documentation Files and What They Track

| File | Sections to Watch |
|------|-------------------|
| `README.md` | Cluster table (roles + machine specs); repo structure tree; quick-reference commands |
| `AGENTS.md` | Repo layout tree; module+cluster pattern table; version location table; operational commands |
| `docs/architecture.md` | Cluster roles table; technology stack table; design-decision narratives; bootstrap sequence diagram |
| `docs/iac.md` | Directory structure tree; bootstrap sequences (server3, server1/server2); module variable reference tables |

See [doc-map](./references/doc-map.md) for the precise section-to-source mapping.

## Procedure

### 1. Identify What Changed

Read the changed files or use git diff to understand the scope:
```bash
git diff --name-only HEAD~1
```

### 2. Map Changes to Affected Doc Sections

Use the [doc-map](./references/doc-map.md) to determine which doc sections are candidates for staleness.

### 3. Read the Current Docs

Read every affected doc file in full before making changes — never edit blindly.

### 4. Apply Updates (per change type)

Follow the rules below, then verify each doc against the codebase.

---

#### Cluster added / removed

| Doc | What to update |
|-----|----------------|
| `README.md` | Cluster table: add/remove row with role and machine specs |
| `AGENTS.md` | Repo layout tree under `iac/clusters/` and `gitops/`; version location table if new stages exist |
| `docs/architecture.md` | Cluster roles table; bootstrap sequence diagram boxes |
| `docs/iac.md` | Directory structure tree; add/remove cluster-specific bootstrap section |

---

#### App added / removed (ArgoCD-managed)

| Doc | What to update |
|-----|----------------|
| `AGENTS.md` | "Adding a new ArgoCD app" section if steps changed |
| `docs/architecture.md` | Technology stack table: add row with component, "ArgoCD", and notes |

---

#### Terraform module added / removed / renamed

| Doc | What to update |
|-----|----------------|
| `AGENTS.md` | Repo layout tree; version location table |
| `docs/iac.md` | Directory structure tree; module variable reference section (add/remove table) |

---

#### Terraform stage added / removed (e.g. new `vault` stage for a cluster)

| Doc | What to update |
|-----|----------------|
| `AGENTS.md` | Repo layout tree; version location table |
| `docs/iac.md` | Directory structure tree; bootstrap sequence for that cluster |
| `docs/architecture.md` | Bootstrap sequence diagram; technology stack table |

---

#### Version bump (any component)

| Doc | What to update |
|-----|----------------|
| `AGENTS.md` | Version location table: verify the `main.tf` path and variable name are still correct |

Never put the actual version number in docs — docs reference *where* the version lives, not the value.

---

#### Directory structure change

| Doc | What to update |
|-----|----------------|
| `README.md` | Repo structure tree if top-level dirs changed |
| `AGENTS.md` | Repo layout tree |
| `docs/iac.md` | Directory structure tree |

---

#### Bootstrap sequence change (new step, reordered step, manual action)

| Doc | What to update |
|-----|----------------|
| `docs/iac.md` | Relevant cluster bootstrap section (numbered steps + code blocks) |
| `docs/architecture.md` | Bootstrap sequence diagram (ASCII box) |

---

#### Machine spec change (RAM, CPU, disk)

| Doc | What to update |
|-----|----------------|
| `README.md` | Cluster table `Machine` column |
| `docs/architecture.md` | Cluster roles table `Machine` column |

---

### 5. Cross-Check Consistency

After all edits, verify that these items are consistent across **all four docs**:

- [ ] Cluster names and count
- [ ] Cluster roles (which cluster runs what)
- [ ] Which cluster runs ArgoCD (server3 only)
- [ ] Which clusters have a `vault` stage (server3 only)
- [ ] Which clusters have an `apps` stage (server3 only)
- [ ] Directory trees agree with actual workspace layout
- [ ] Bootstrap sequences agree between `docs/iac.md` and `docs/architecture.md`
- [ ] `AGENTS.md` version table lists every Terraform-managed component that exists

### 6. Verify Against Actual Files

For directory trees and file references, confirm against the workspace:
```bash
find iac/modules -maxdepth 1 -mindepth 1 -type d | sort
find iac/clusters -maxdepth 3 -mindepth 3 -type d | sort
find gitops -maxdepth 2 -mindepth 1 -type d | sort
```

### 7. Do NOT Change

- Architecture decision rationale (the "Why" sections) — only update if the decision itself changed
- The `docs/secrets.md` placeholder reference — do not create or remove it
- Gitignored credential paths — they are correct by design
- Component version values — docs track *location*, not values
