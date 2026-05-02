# Design Spec: Factory Pipeline Refactor — Deterministic Replicated SDK Onboarding

**Repo:** replicated-collab/factory
**Date:** 2026-04-27
**Status:** Draft

## Problem

The current Factory pipeline produces incomplete PRs. PR #5 on kriscoleman/slackernews only modified 2 files (Chart.yaml + values.yaml) out of ~10 required artifacts. The agent completes in 6 turns without doing the full integration. Review gates rubber-stamp the output. The pipeline needs to be rebuilt with deterministic outcomes.

## Design Principles

1. **The launch plugin IS the spec** — every job reads its corresponding skill file for expert-level guidance
2. **Multi-job pipeline** — one focused job per skill step, not one monolithic agent trying to do everything
3. **Parallel where independent** — install-sdk, configure-values, setup-cicd, and update-kots run concurrently
4. **Self-verification checklists** — each job verifies its own output before committing
5. **All gates are hard gates** — pipeline iterates until ALL pass, including CMX deploy
6. **CMX feedback loop** — implement → release → validate in CMX → iterate until healthy
7. **Custom proxy domains are valid** — agents must detect and preserve them, not replace with `registry.replicated.com`
8. **Both greenfield and existing repos** — fill gaps + upgrade v2 patterns to v3

## Pipeline Architecture

### Onboard Workflow (`onboard.yml`)

```
  assess-repo (Job 1)
      │ outputs: chart_dir, sdk_state, kots_state, custom_proxy_domain, etc.
      │
      ├──→ install-sdk        (branch: factory/step-sdk)
      ├──→ configure-values   (branch: factory/step-values)
      ├──→ setup-cicd         (branch: factory/step-cicd)
      └──→ update-kots        (branch: factory/step-kots)
              │
              ▼
      merge-branches (rebase each onto factory/replicated-onboarding)
              │
              ▼
      dispatch review.yml
```

### Review Workflow (`review.yml`)

```
  ┌─ Gate 1: Deterministic assertions (file checks)
  ├─ Gate 2: CI checks (helm lint, replicated lint)
  ├─ Gate 3: AI code review (review-agent.md 8-check checklist)
  └─ Gate 4: CMX deploy (release, provision, deploy, pod health)
              │
              ▼
      ALL pass? → Open PR
      ANY fail? → Dispatch onboard iteration N+1 with combined feedback
```

## Job Specifications

### Job 1: assess-repo

**Reads:** `_factory/.claude/plugins/launch/skills/assess-repo/SKILL.md`

**Purpose:** Inspect the repo and output structured metadata for downstream jobs.

**Claude's task:** Follow the assess-repo skill procedure to detect chart structure, SDK state, KOTS patterns, custom domains, and install type.

**Outputs** (GitHub Actions job outputs):

```json
{
  "chart_dir": "chart/slackernews",
  "chart_name": "slackernews",
  "chart_version": "0.4.14",
  "sdk_present": true,
  "sdk_repo_url": "oci://chart.slackernews.io/library",
  "sdk_version": "1.14.0",
  "sdk_needs_fix": false,
  "global_replicated_present": false,
  "replicated_app_yaml_present": false,
  "kots_dir": "kots",
  "kots_present": true,
  "kots_patterns": "v2",
  "custom_proxy_domain": "chart.slackernews.io",
  "has_cicd_workflow": false,
  "install_type": "ec-vm",
  "ec_version": "3.0.0-alpha-15+k8s-1.34"
}
```

**Custom proxy domain detection:** Checks `embedded-cluster.yaml` for `spec.domains.proxyRegistryDomain` and KOTS HelmChart CRs for image proxy patterns. If a custom domain is found, it's passed downstream so agents do NOT replace it.

**`sdk_needs_fix` logic:** True when:
- Version pinned below 1.17.0 (or below 1.19.2 for EC v3)
- Repository is NOT `oci://registry.replicated.com/library` AND NOT the detected custom proxy domain

**Downstream job conditions:**

| Job | Runs when |
|-----|-----------|
| install-sdk | `!sdk_present` OR `sdk_needs_fix` |
| configure-values | `!global_replicated_present` |
| setup-cicd | `!has_cicd_workflow` |
| update-kots | `kots_present` AND `kots_patterns == 'v2'` |

### Jobs 2a-2d: Parallel Skill Jobs

Each follows the same template:

```yaml
steps:
  - checkout customer repo at factory/replicated-onboarding
  - checkout Factory to _factory/
  - read assess-output.json for metadata
  - check condition (skip if not needed)
  - run claude-code-action:
      prompt: "Read _factory/.claude/plugins/launch/skills/<name>/SKILL.md.
              Make ONLY the changes this skill requires.
              Context: [assess metadata, custom_proxy_domain].
              Verify checklist before finishing."
      claude_args: --max-turns 50 --model claude-opus-4-7
                   --permission-mode acceptEdits
                   --allowedTools "Bash(*)" "Read" "Write" "Edit" "Glob" "Grep"
  - deterministic self-check (grep assertions)
  - fail job if self-check fails
  - commit to own branch (factory/step-<name>)
  - push branch to customer repo
```

**Note:** Max turns reduced to 50 per job (focused scope) vs 200 for the old monolithic approach.

#### install-sdk

**Reads:** `skills/install-sdk/SKILL.md`
**Context:** chart_dir, sdk_present, sdk_needs_fix, custom_proxy_domain

**What Claude does:**
- If SDK missing: add dependency to Chart.yaml, create replicated-app.yaml
- If SDK needs fix: update version range (NOT repo URL if it matches custom_proxy_domain)
- Create `<chart_dir>/replicated-app.yaml` if missing

**Self-check:**
```bash
grep -q "name: replicated" "$CHART_DIR/Chart.yaml" || fail
test -f "$CHART_DIR/replicated-app.yaml" || fail
grep -q "apiVersion: kots.io/v1beta1" "$CHART_DIR/replicated-app.yaml" || fail
```

#### configure-values

**Reads:** `skills/configure-values/SKILL.md`
**Context:** chart_dir

**What Claude does:**
- Add `global.replicated` block with all 11 fields to values.yaml
- Merge under existing `global:` key if present

**Self-check:**
```bash
grep -q "global:" "$CHART_DIR/values.yaml" || fail
grep -A1 "global:" "$CHART_DIR/values.yaml" | grep -q "replicated:" || fail
grep -q "customerName" "$CHART_DIR/values.yaml" || fail
grep -q "licenseID" "$CHART_DIR/values.yaml" || fail
```

#### setup-cicd

**Reads:** `skills/setup-cicd/SKILL.md`
**Context:** chart_dir, chart_name

**What Claude does:**
- Create `.github/workflows/replicated-release.yaml`
- Use Replicated CLI directly (install latest, `replicated release create` / `replicated release promote`)
- Reference correct chart path and secrets

**Self-check:**
```bash
test -f ".github/workflows/replicated-release.yaml" || fail
grep -q "replicated release" ".github/workflows/replicated-release.yaml" || fail
grep -q "REPLICATED_API_TOKEN" ".github/workflows/replicated-release.yaml" || fail
```

#### update-kots

**Reads:** `skills/ec-v3-migrate/SKILL.md` + `skills/install-sdk/SKILL.md` (KOTS sections)
**Context:** chart_dir, kots_dir, kots_patterns, custom_proxy_domain, ec_version

**What Claude does:**
- Update v2 patterns to v3 (HasLocalRegistry → IsAirgap, LocalRegistryHost → ReplicatedImageName)
- Fix bare `{{repl` to `repl{{ }}` prefix form
- Preserve custom proxy domain references
- Update preflight apiVersion to v1beta3 if needed
- Ensure SDK version ≥ 1.19.2 for EC v3

**Self-check:**
```bash
! grep -q "HasLocalRegistry" "$KOTS_DIR"/*.yaml || fail
! grep -q "LocalRegistryHost" "$KOTS_DIR"/*.yaml || fail
! grep -rq '{{repl ' "$KOTS_DIR"/*.yaml || fail
```

### Job 3: merge-branches

**Runs after:** all parallel jobs complete (including skipped)

**Steps:**
1. Checkout customer repo at `main`
2. Create `factory/replicated-onboarding` branch
3. For each step branch that exists, cherry-pick its commits:
   ```bash
   for BRANCH in factory/step-sdk factory/step-values factory/step-cicd factory/step-kots; do
     if git ls-remote --heads origin "$BRANCH" | grep -q .; then
       git fetch origin "$BRANCH"
       git cherry-pick origin/$BRANCH --no-commit
       git commit -m "feat: $BRANCH changes"
     fi
   done
   ```
4. Push `factory/replicated-onboarding`
5. Clean up step branches
6. Dispatch review.yml

### Job 4: dispatch review

Passes: repo_owner, repo_name, installation_id, working_branch, iteration

## Review Workflow

### Gate 1: Deterministic Assertions (hard gate)

Pure shell. No AI. Checks every artifact.

```bash
CHART_DIR="<from assess>"
KOTS_DIR="<from assess>"
ERRORS=""

# SDK dependency
grep -q "name: replicated" "$CHART_DIR/Chart.yaml" \
  || ERRORS+="Missing SDK dependency in Chart.yaml. "

# replicated-app.yaml
test -f "$CHART_DIR/replicated-app.yaml" \
  || ERRORS+="Missing replicated-app.yaml. "

# global.replicated
grep -q "customerName" "$CHART_DIR/values.yaml" \
  || ERRORS+="Missing global.replicated in values.yaml. "

# CI workflow
test -f ".github/workflows/replicated-release.yaml" \
  || ERRORS+="Missing CI/CD workflow. "

# KOTS v2 patterns (if kots dir exists)
if [ -d "$KOTS_DIR" ]; then
  grep -rq "HasLocalRegistry" "$KOTS_DIR"/*.yaml \
    && ERRORS+="v2 KOTS pattern HasLocalRegistry still present. "
  grep -rq '{{repl ' "$KOTS_DIR"/*.yaml \
    && ERRORS+="Bare {{repl syntax in KOTS manifests. "
fi

if [ -n "$ERRORS" ]; then
  echo "gate1_passed=false"
  echo "gate1_feedback=$ERRORS"
else
  echo "gate1_passed=true"
fi
```

### Gate 2: CI Checks (hard gate)

```bash
helm dependency update "$CHART_DIR"
helm lint "$CHART_DIR" || fail
helm template test "$CHART_DIR" || fail

if [ -d "$KOTS_DIR" ]; then
  replicated release lint --yaml-dir "$KOTS_DIR" || fail
fi
```

### Gate 3: AI Code Review (hard gate)

Claude reads `agents/review-agent.md` and performs the full 8-check validation. Outputs `REVIEW_PASSED=true|false` with specific feedback. Deterministic assertions from Gate 1 supplement but Claude's expert review catches nuanced issues (image refs not templated, missing status informers, incorrect KOTS template syntax patterns).

### Gate 4: CMX Deploy (hard gate)

The ultimate validator. If pods are healthy, the integration works.

```yaml
steps:
  - helm package chart
  - replicated release create --promote Unstable
  - replicated cluster create --distribution k3s --ttl 1h --wait 5m
  - get kubeconfig
  - helm install from Replicated registry
  - poll pods (5 min timeout, app namespace)
  - if unhealthy: collect kubectl logs, describe, events
  - ALWAYS tear down cluster
  - pass/fail based on pod health
```

**On failure:** pod logs and events become the feedback for the next onboard iteration. This is the most actionable feedback — "CrashLoopBackOff: image pull failed for registry.example.com/app:latest" tells the agent exactly what to fix.

### Finalize

```
ALL 4 gates pass → Open PR with:
  - Validation results table
  - Code review findings
  - CMX deploy results
  - Files changed
  - Secrets setup instructions

ANY gate fails → Dispatch onboard iteration N+1 with:
  - Combined feedback from all failed gates
  - Gate 4 pod logs if CMX failed
  - Max 10 iterations, then escalate
```

## Prompt Architecture

Each job gets a focused prompt that:
1. States the single task clearly
2. Points to the skill file to read
3. Provides assess metadata as context
4. Includes the self-verification checklist
5. Includes iteration feedback if applicable

### Template:

```
You are the [SKILL_NAME] agent in Factory's onboard pipeline.

## Your single task
[One sentence: what you must do]

## Reference
Read _factory/.claude/plugins/launch/skills/[SKILL]/SKILL.md for
the exact patterns and requirements.

## Context from assessment
- Chart directory: [chart_dir]
- Custom proxy domain: [custom_proxy_domain] (DO NOT replace this)
- [other relevant metadata]

## Iteration feedback
[feedback from prior review, if any]

## Checklist (verify ALL before finishing)
- [ ] [specific file exists]
- [ ] [specific content present]
- [ ] [specific pattern correct]

You MUST make actual file changes. Do NOT just analyze.
Do NOT commit or push. Do NOT run helm or replicated CLI.
```

## Custom Proxy Domain Handling

Assess-repo detects custom proxy domains from:
- `embedded-cluster.yaml` → `spec.domains.proxyRegistryDomain`
- KOTS HelmChart CRs → image references using non-standard registry domains
- Chart.yaml → SDK repository URL that isn't `registry.replicated.com`

The custom domain is passed to ALL downstream jobs. Agents must:
- NOT replace the custom domain with `registry.replicated.com`
- NOT flag the custom domain as "wrong" in reviews
- Preserve it in all image references and proxy configurations
- Only fix the SDK version range, not the repository URL

## Iteration Limits

- Max 10 iterations per onboard cycle
- Each iteration redispatches the FULL parallel job set (assess → skill jobs → merge → review)
- Feedback from failed gates is injected into each skill job's prompt
- After 10 iterations: escalate with an issue on the Factory repo documenting what failed

## What This Replaces

The current single-job, single-prompt approach where one Claude instance tries to do everything in 200 turns. That approach:
- Completed only 20% of the work
- Had no self-verification
- Had advisory-only review gates
- Treated CMX deploy as optional
- Ignored existing KOTS manifests

The new pipeline has 6 focused jobs, each reading expert guidance from the launch plugin, with deterministic + AI + deployment validation before any PR is opened.
