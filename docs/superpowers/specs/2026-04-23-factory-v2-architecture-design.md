# Design Spec: Factory v2 — Automated Replicated SDK Onboarding

**Repo:** replicated-collab/factory
**Date:** 2026-04-23
**Status:** Draft

## Overview

Factory v2 replaces the Kubernetes-deployed SaaS (Go backend, React frontend, PostgreSQL, Redis, DAPR) with a pure GitHub Actions architecture. A customer installs the Factory GitHub App, selects repos, and Factory autonomously implements the Replicated SDK, validates deployment to CMX, and opens a polished PR — all without the customer doing any work.

## Architecture

Factory is a **GitHub App + GitHub Actions workflow repo**. No backend, no frontend, no database, no infrastructure to deploy or maintain.

```
Customer installs GitHub App → selects repos
        │
        ▼
installation webhook (future: auto-dispatch)
        │
  MVP: manual workflow_dispatch with repo details
        │
        ▼
┌─────────────────────────────────────────────────┐
│  replicated-collab/factory (GitHub Actions)      │
│                                                  │
│  onboard.yml                                     │
│  ├── Generate installation token                 │
│  ├── Clone customer repo (private)               │
│  ├── launch:coding-agent implements SDK          │
│  ├── Commit to internal working branch           │
│  └── Dispatch review.yml                         │
│                                                  │
│  review.yml                                      │
│  ├── Gate 1: Code review (fast, free)            │
│  ├── Gate 2: CI checks (helm lint, replicated    │
│  │           lint — medium, free)                 │
│  ├── Gate 3: CMX deploy (provision, deploy,      │
│  │           verify pods — slow, costs credits)   │
│  ├── Gate 4: Final judgment                      │
│  │                                               │
│  ├── If issues → @mention coding-agent → iterate │
│  └── If healthy → push to customer repo,         │
│       open PR as bot                             │
└─────────────────────────────────────────────────┘
        │
        ▼
Customer sees: one clean PR with Replicated SDK
integrated, validated, ready to merge
```

### What Gets Deleted

The entire v1 infrastructure is removed:

- `backend/` — Go server, handlers, DB, GitHub client
- `frontend/` — React dashboard
- `charts/` — Helm chart, PostgreSQL, Redis, Replicated subcharts
- All CI/CD deploy workflows
- Docker-related files
- Database migrations

### What Remains

```
replicated-collab/factory/
├── .github/
│   └── workflows/
│       ├── onboard.yml          # Coding-agent workflow
│       └── review.yml           # Review-agent workflow
├── setup/
│   ├── create-github-app.html   # GitHub App creation flow
│   └── exchange-code.sh         # Token exchange script
├── prompts/
│   ├── coding-agent.md          # System prompt for coding-agent
│   └── review-agent.md          # System prompt for review-agent
├── CLAUDE.md
└── README.md                    # How Factory works + manual dispatch instructions
```

## Workflow Design

### `onboard.yml` — Coding Agent

**Trigger:** `workflow_dispatch`

**Inputs:**
| Input | Required | Description |
|-------|----------|-------------|
| `repo_owner` | yes | Customer repo owner (org or user) |
| `repo_name` | yes | Customer repo name |
| `installation_id` | yes | GitHub App installation ID |
| `iteration` | no | Loop counter (default: 1, max: 10) |
| `feedback` | no | Review feedback from previous iteration |

**Steps:**

1. **Generate installation token** — `actions/create-github-app-token` with App ID + private key + installation ID. Scoped to the customer's repo.

2. **Clone customer repo** — `git clone` using the installation token. Private, internal to the Action runner.

3. **Run Claude Code Action** — `anthropics/claude-code-action@v1` with:
   - Prompt loaded from `prompts/coding-agent.md`
   - Context: customer repo contents, iteration number, any feedback from prior review
   - Skills: `launch:assess-repo`, `launch:install-sdk`, `launch:create-helm-chart`, `launch:setup-cicd`, `launch:configure-values`
   - The coding-agent assesses the repo, creates a Helm chart if needed, installs the SDK, adds KOTS manifests, and sets up CI/CD

4. **Commit to internal working branch** — Changes committed to a branch in Factory's repo (e.g., `work/{repo_owner}/{repo_name}`) so the customer repo stays clean during iteration.

5. **Dispatch review workflow** — `workflow_dispatch` to `review.yml` with repo details and branch ref.

### `review.yml` — Review Agent

**Trigger:** `workflow_dispatch`

**Inputs:**
| Input | Required | Description |
|-------|----------|-------------|
| `repo_owner` | yes | Customer repo owner |
| `repo_name` | yes | Customer repo name |
| `installation_id` | yes | GitHub App installation ID |
| `working_branch` | yes | Branch ref with the SDK implementation |
| `iteration` | no | Current iteration count |

**Steps — Layered Gates:**

**Gate 1: Code Review (fast, free)**
- Claude Code Action with `launch:review-agent` prompt
- Reviews the diff against Replicated SDK best practices
- Checks: Chart.yaml structure, values.yaml patterns, KOTS manifest completeness, image proxy configuration, preflight definitions
- If fails → dispatch `onboard.yml` with feedback, increment iteration

**Gate 2: CI Checks (medium, free)**
- `helm lint` on the chart
- `helm template` to verify rendering
- `replicated release lint --yaml-dir` on the KOTS manifests
- If fails → dispatch `onboard.yml` with lint errors as feedback

**Gate 3: CMX Deploy (slow, costs credits)**
- `replicated release create` with the packaged chart
- `replicated cluster create --distribution k3s --version 1.32 --ttl 1h`
- `helm install` from the Replicated registry
- Wait for pods healthy (`kubectl get pods --field-selector=status.phase!=Running,status.phase!=Succeeded`)
- If unhealthy → collect pod logs, describe events → dispatch `onboard.yml` with diagnostic feedback
- Tear down cluster regardless of outcome

**Gate 4: Final Judgment**
- Claude Code Action reviews the full integration holistically
- Confirms all gates passed
- If approved → proceed to PR creation

**PR Creation (all gates passed):**
- Push the working branch to customer repo using installation token
- `gh pr create --repo {owner}/{repo}` as the GitHub App bot
- PR body includes: what was done, what was validated, CMX deploy results
- Mark as ready for review (not draft — the work is validated)

### Loop Control

- **Max iterations:** 10 (passed as `iteration` input, checked at start of each workflow)
- **Escalation at max:** Open an issue in Factory repo with full context. Do NOT open a broken PR on the customer repo.
- **Each iteration** is a separate workflow run — full audit trail in GitHub Actions.
- **Feedback threading:** Review feedback is passed as a workflow input string to the next coding-agent iteration, giving it specific instructions on what to fix.

## Token & Authentication

| Step | Token Type | Source |
|------|-----------|--------|
| Clone customer repo | Installation token | `actions/create-github-app-token` (App ID + PEM + installation ID) |
| Run Claude Code Action | Anthropic API key | Repo secret `ANTHROPIC_API_KEY` |
| Push branch to customer repo | Installation token | Same as clone |
| Open PR on customer repo | Installation token | Same token, `gh pr create --repo` |
| Provision CMX cluster | Replicated API token | Repo secret `REPLICATED_API_TOKEN` |
| Create Replicated release | Replicated API token | Same + repo secret `REPLICATED_APP` |
| Dispatch between workflows | GitHub token | Built-in `GITHUB_TOKEN` |

**Secrets required in Factory repo:**
- `APP_ID` — GitHub App ID
- `APP_PRIVATE_KEY` — GitHub App private key (PEM)
- `ANTHROPIC_API_KEY` — for Claude Code Action
- `REPLICATED_API_TOKEN` — for CMX + Replicated CLI
- `REPLICATED_APP` — for release creation during validation

**No customer secrets needed.** Installation token provides all repo access.

## Agent Prompts

### `prompts/coding-agent.md`

The coding-agent prompt instructs Claude Code to:
1. Use `launch:assess-repo` to understand the repo structure
2. If no Helm chart exists, use `launch:create-helm-chart`
3. Use `launch:install-sdk` to add the Replicated SDK subchart
4. Use `launch:configure-values` to set up SDK license metadata
5. Use `launch:setup-cicd` to add GitHub Actions release workflow
6. If EC is needed, set up embedded-cluster.yaml
7. If feedback from a prior iteration is provided, address those specific issues first

### `prompts/review-agent.md`

The review-agent prompt instructs Claude Code to:
1. Review the diff as a Replicated integration expert
2. Check against known patterns (helmchart.yaml value rules, image proxy setup, preflight definitions, builder section)
3. Run helm lint and replicated release lint
4. If all checks pass, provision CMX and deploy
5. Provide specific, actionable feedback if issues are found
6. Make a final go/no-go judgment

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Customer repo has no Dockerfile | `launch:assess-repo` + `launch:create-helm-chart` handle from scratch |
| Customer repo already has Replicated SDK | Coding-agent detects, skips. Review-agent validates existing setup. |
| CMX cluster fails to provision | Retry once. If still fails, skip CMX gate. Note in PR body that deploy validation was skipped. |
| Claude Code Action times out (6hr) | Workflow fails. Next iteration picks up from committed state. |
| Max iterations (10) reached | Stop. Open issue in Factory repo with context. Do NOT PR to customer repo. |
| Customer removes GitHub App mid-onboard | Token invalid. Workflow fails gracefully. Clean up internal branch. |
| Multiple repos in single installation | Each repo gets independent `workflow_dispatch`. Run in parallel. |

## MVP Scope

**In scope:**
- Manual `workflow_dispatch` trigger with repo owner/name/installation ID
- Coding-agent with launch skills
- Review-agent with layered gates (code review → CI → CMX → judgment)
- Iteration loop with max 10 cycles
- PR creation on customer repo as bot
- Clear README with manual dispatch instructions

**Out of scope (post-MVP):**
- Automatic webhook-to-dispatch bridge (installation event auto-triggers)
- Vendor Portal integration ("Use AI to onboard" button)
- CMX VM-based Claude Code execution (zero customer-visible noise option)
- Dashboard/UI for monitoring onboarding status
- Persistent state tracking across repos
- Customer notifications/emails

## Manual Dispatch Instructions (for README)

```bash
# 1. Customer installs the Factory GitHub App on their repo

# 2. Find the installation ID:
gh api /app/installations --jq '.[] | select(.account.login == "CUSTOMER_ORG") | .id'

# 3. Trigger the onboard workflow:
gh workflow run onboard.yml \
  --repo replicated-collab/factory \
  -f repo_owner=CUSTOMER_ORG \
  -f repo_name=THEIR_REPO \
  -f installation_id=INSTALLATION_ID

# 4. Monitor progress in GitHub Actions:
#    https://github.com/replicated-collab/factory/actions

# 5. When complete, customer sees a PR on their repo
#    with Replicated SDK integrated and validated
```
