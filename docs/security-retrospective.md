# Security Retrospective: Zero CVE Journey (Epic #161)

**Epic:** [#161](https://github.com/replicated-collab/FirstResponse/issues/161) -- Achieve zero CVEs across all container images
**Start date:** 2026-04-20
**End date:** 2026-04-21
**Outcome:** All Critical and High CVEs eliminated from application images; subchart images pinned to latest patches; CI gates and automation in place to prevent regression.

---

## Quick Reference

| Metric | Before | After |
|--------|--------|-------|
| **Backend CVEs** | 22 (2 Critical, 13 High, 7 Medium) | 0 Critical, 0 High, 2 Medium (unfixable) |
| **Frontend CVEs** | 17 (0 Critical, 3 High, 13 Medium, 1 Low) | 0 Critical, 0 High, 1 Medium (busybox, unfixable) |
| **Subchart images** | Floating tags (`postgres:16`, `redis:7`) | Pinned (`postgres:16.13`, `redis:7.4.8`) |
| **CI CVE scanning** | None | Grype on every PR, fail-on-critical, SARIF upload |
| **Dependency automation** | None | Dependabot (Go, npm, Docker, GitHub Actions) + Troubleshoot monitor |
| **PRs merged** | -- | 11 |
| **Lines changed** | -- | 815 (+787 / -28) |

---

## 1. Executive Summary

Over two days (April 20-21, 2026), we took the FirstResponse application from 39 known CVEs across two application images and uncounted CVEs in floating subchart images to a state where all Critical and High vulnerabilities are eliminated, CI blocks future Critical CVEs from merging, and automation keeps dependencies current. Eleven PRs were merged, touching CI workflows, Dockerfiles, Helm chart values, and adding new monitoring infrastructure. Three CVEs remain with no upstream fix available (2 docker/docker in backend, 1 busybox in frontend) and are tracked for quarterly re-evaluation.

---

## 2. Baseline (Before)

The CVE audit ([PR #169](https://github.com/replicated-collab/FirstResponse/pull/169)) established the baseline on 2026-04-20 using Grype 0.111.0:

### Application images

| Image | Critical | High | Medium | Low | Total |
|-------|----------|------|--------|-----|-------|
| Backend (`backend:latest`) | 2 | 13 | 7 | 0 | **22** |
| Frontend (`frontend:latest`) | 0 | 3 | 13 | 1 | **17** |
| **Total** | **2** | **16** | **20** | **1** | **39** |

- **Backend:** All 22 CVEs originated from the bundled Troubleshoot `support-bundle` binary (v0.125.1, compiled with Go 1.26.1). The FirstResponse server binary itself had zero CVEs.
- **Frontend:** All 17 CVEs originated from Alpine 3.23.4 OS packages (curl, tiff, busybox, nghttp2) in the `nginx:alpine` base image. Zero CVEs in application-level Node.js code.

### Subchart images

| Image | Estimated CVEs | Root Cause |
|-------|---------------|------------|
| `postgres:16` (floating tag) | ~75 | Debian base, never updated after initial pull |
| `redis:7` (floating tag) | ~56 | Debian base, never updated after initial pull |

### Infrastructure gaps

- No CVE scanning in CI pipeline
- No Dependabot or Renovate for dependency updates
- No Troubleshoot version monitoring
- No visibility into subchart image security posture

---

## 3. Root Cause Analysis

Four architectural decisions created the conditions for CVE accumulation:

### 3.1 Troubleshoot binary bundled at build time with no update mechanism

The backend Dockerfile downloaded a pre-built `support-bundle` binary at a pinned version (v0.125.1) and baked it into the image. This binary was compiled with Go 1.26.1 and carried 22 transitive dependency CVEs. There was no mechanism to detect when a newer Troubleshoot release was available, so Go stdlib CVEs accumulated silently between releases.

**Impact:** 22 of 39 total CVEs (2 Critical, 13 High, 7 Medium).

### 3.2 Floating Docker tags for subchart images

The Helm chart referenced `postgres:16` and `redis:7` -- floating major-version tags. These resolved to whatever image was current when the cluster first pulled them and were never updated. Both use Debian base images with large package surfaces.

**Impact:** ~131 combined CVEs in PostgreSQL and Redis images, completely invisible to the team.

### 3.3 No CVE scanning in CI

Without Grype (or any scanner) in the CI pipeline, there was no automated check for new vulnerabilities. CVEs entered the codebase silently and persisted indefinitely.

**Impact:** Zero visibility into security posture until the manual audit.

### 3.4 No dependency update automation

No Dependabot, Renovate, or any automated dependency update tooling was configured. Go modules, npm packages, Dockerfile base images, and GitHub Actions all drifted.

**Impact:** Known-fixed CVEs persisted because nobody was notified when upstream fixes shipped.

---

## 4. Remediation Timeline

All dates are merge dates. PRs are listed in chronological order.

### Phase 1: Visibility (2026-04-20)

| PR | Title | Impact |
|----|-------|--------|
| [#162](https://github.com/replicated-collab/FirstResponse/pull/162) | feat(ci): add Grype CVE scanning to CI/CD pipeline | Added Grype scanning for backend and frontend images on every PR. SARIF upload to GitHub Security tab. Sticky PR comments with severity breakdown. Initially set `fail-build: false` to establish baseline without breaking existing PRs. (+259 / -8) |
| [#169](https://github.com/replicated-collab/FirstResponse/pull/169) | docs: CVE audit report and remediation plan | Comprehensive audit documenting all 39 CVEs with root causes, affected packages, fix availability, and prioritized remediation plan. This became the roadmap for the rest of the work. (+295 / -0) |

### Phase 2: Remediation (2026-04-20)

| PR | Title | Impact |
|----|-------|--------|
| [#172](https://github.com/replicated-collab/FirstResponse/pull/172) | fix(backend): upgrade Troubleshoot support-bundle to v0.127.0 | Bumped `TROUBLESHOOT_VERSION` from v0.125.1 to v0.127.0. Eliminated 20 of 22 backend CVEs (1 Critical + 12 High + 5 Medium from Go stdlib and transitive dependencies fixed upstream). (+1 / -1) |
| [#174](https://github.com/replicated-collab/FirstResponse/pull/174) | fix(backend): upgrade Go toolchain to 1.26.2 | Changed builder stages from `golang:1.26-bookworm` to `golang:1.26.2-bookworm` and updated `go.mod`. Hardened the FirstResponse server binary against the same stdlib CVEs and ensured future builds use the patched toolchain. (+14 / -6) |
| [#177](https://github.com/replicated-collab/FirstResponse/pull/177) | fix(frontend): reduce base image attack surface and update Alpine packages | Switched from `nginx:alpine` to `nginx:alpine-slim` and added `apk upgrade --no-cache`. Eliminated 14 of 17 frontend CVEs by removing curl (10 CVEs), tiff (3 CVEs), and nghttp2 (1 CVE) which were unused by the application. (+6 / -1) |

### Phase 3: Enforce and Expand (2026-04-20 to 2026-04-21)

| PR | Title | Impact |
|----|-------|--------|
| [#183](https://github.com/replicated-collab/FirstResponse/pull/183) | fix(ci): enable fail-build on Critical CVEs after remediation | Flipped `fail-build` from `false` to `true` with `severity-cutoff: critical` on both scan steps. Critical CVEs now block PR merges. (+4 / -5) |
| [#186](https://github.com/replicated-collab/FirstResponse/pull/186) | fix(helm): upgrade PostgreSQL subchart and image to reduce CVEs | Pinned `postgres:16` to `postgres:16.13` (latest patch). (+1 / -1) |
| [#187](https://github.com/replicated-collab/FirstResponse/pull/187) | fix(helm): upgrade Redis subchart and image to reduce CVEs | Pinned `redis:7` to `redis:7.4.8` (latest patch). (+1 / -1) |
| [#188](https://github.com/replicated-collab/FirstResponse/pull/188) | feat(ci): expand CVE scanning to include subchart images (postgres, redis) | Added Grype scanning for PostgreSQL and Redis subchart images, reading tags from `values.yaml`. Subchart scans are informational (do not fail build) since we don't control upstream. SARIF uploaded for full visibility. (+87 / -5) |

### Phase 4: Automation (2026-04-21)

| PR | Title | Impact |
|----|-------|--------|
| [#190](https://github.com/replicated-collab/FirstResponse/pull/190) | chore(ci): add Troubleshoot version monitor workflow | Weekly cron workflow checks for new Troubleshoot releases and auto-creates GitHub issues when updates are available. Prevents the silent drift that caused the original 22 backend CVEs. (+72 / -0) |
| [#191](https://github.com/replicated-collab/FirstResponse/pull/191) | chore(ci): add Dependabot config for Go, npm, Docker, and GitHub Actions | Configured Dependabot for all five dependency ecosystems (Go modules, npm, backend Docker, frontend Docker, GitHub Actions). Weekly schedule. Already generated 9 PRs within hours of merging. (+47 / -0) |

---

## 5. Friction Log

Issues encountered during remediation, in case they recur or inform future decisions:

### Alpine UID/GID mismatch with groundhog2k charts

We initially investigated using Alpine-based PostgreSQL and Redis images to reduce attack surface (mirroring the frontend approach). The groundhog2k subchart charts assume Debian UID/GID conventions. Alpine images use different defaults, causing permission failures on persistent volume mounts. We abandoned this approach and instead pinned to the latest Debian patch versions.

### 2 backend CVEs with no upstream fix (docker/docker)

Two CVEs in `github.com/docker/docker` (GHSA-x744-4wpc-v9h2, High -- AuthZ plugin bypass; GHSA-pxq6-2prw-chj9, Medium -- off-by-one in plugin privilege validation) have no fix available. These are transitive dependencies pulled in by the Troubleshoot binary. We cannot remove them without forking Troubleshoot. Tracked for quarterly re-evaluation.

### 1 frontend CVE that cannot be removed from Alpine (busybox)

CVE-2025-60876 (busybox wget HTTP request-target injection, Medium) affects `busybox`, `busybox-binsh`, and `ssl_client` packages. Even `nginx:alpine-slim` includes busybox as it provides the shell and core utilities. Removing it would break the image. Accepted as unfixable for Alpine-based images.

### Grype scan only covered app images initially

The initial Grype setup (PR #162) only scanned the backend and frontend images built in CI. Subchart images (PostgreSQL, Redis) were invisible. This was a significant visibility gap -- the subchart images had far more CVEs than the application images. Fixed in PR #188 by reading subchart image tags from `values.yaml` and scanning them as an informational step.

### Deploy preview failures from stale cluster state

After the Alpine rollback for subchart images, deploy previews on open PRs failed because the CMX test clusters had cached the old image layers. Clusters needed to be recycled to pick up the corrected image tags. This was a transient issue but caused confusion during the remediation window.

### GitHub Actions API rate limits causing transient CI lint failures

The Replicated lint job occasionally failed with HTTP 403 from the GitHub API during periods of high PR activity (11 security PRs + 9 Dependabot PRs in a short window). These were transient and resolved on retry, but they created noise during an already busy remediation.

---

## 6. What We Could Have Done Differently

These are not criticisms -- they are lessons for future projects:

1. **Pin all image tags from day 1.** Never use floating tags like `postgres:16` or `redis:7`. Always specify the full patch version. The cost of updating a pinned tag is trivial; the cost of discovering 131 CVEs in production images is not.

2. **Add CVE scanning to CI from the start.** The Grype integration (PR #162) was 259 lines of YAML. It could have been in the initial CI pipeline. Without scanning, we had zero visibility into our security posture for the entire development period.

3. **Set up Dependabot before the first release.** The Dependabot config (PR #191) was 47 lines. It generated 9 useful PRs within hours. Every week without it was a week of silent dependency drift.

4. **Do not vendor binaries without an update mechanism.** The Troubleshoot `support-bundle` binary was downloaded at build time and never updated. A simple version-check workflow (PR #190, 72 lines) would have caught the Go 1.26.1 CVEs weeks earlier.

5. **Use slim/distroless base images by default.** The switch from `nginx:alpine` to `nginx:alpine-slim` (PR #177) eliminated 14 CVEs with a one-line Dockerfile change. Starting with the minimal image would have prevented those CVEs from ever appearing.

6. **Scan subchart images from the start.** Our initial scanning blind spot meant the worst offenders (131 combined CVEs in PostgreSQL and Redis) were invisible until Phase 3.

---

## 7. Best Practices Adopted

The following practices are now in place and should be maintained:

### CI/CD security gates

- **Grype scanning on every PR** with `fail-build: true` and `severity-cutoff: critical` for application images ([PR #162](https://github.com/replicated-collab/FirstResponse/pull/162), [PR #183](https://github.com/replicated-collab/FirstResponse/pull/183))
- **SARIF upload to GitHub Security tab** for both application and subchart images, providing a centralized view of all vulnerabilities
- **Sticky PR comments** with CVE severity breakdown table, so reviewers see security impact without leaving the PR
- **Subchart image scanning** for PostgreSQL and Redis, informational but visible ([PR #188](https://github.com/replicated-collab/FirstResponse/pull/188))

### Dependency automation

- **Dependabot** configured for Go modules, npm, Docker (backend + frontend), and GitHub Actions ([PR #191](https://github.com/replicated-collab/FirstResponse/pull/191))
- **Troubleshoot version monitor** -- weekly cron workflow that auto-creates issues when new Troubleshoot releases are available ([PR #190](https://github.com/replicated-collab/FirstResponse/pull/190))

### Image hygiene

- **Pinned image tags** -- `postgres:16.13`, `redis:7.4.8`, `golang:1.26.2-bookworm` (no floating major tags)
- **`nginx:alpine-slim`** for minimal frontend attack surface ([PR #177](https://github.com/replicated-collab/FirstResponse/pull/177))
- **`apk upgrade --no-cache`** in frontend Dockerfile to pick up security patches at build time
- **Distroless runtime** (`gcr.io/distroless/static-debian12:nonroot`) for backend -- already in place before this epic

---

## 8. Current State (After)

### Application images

| Image | Critical | High | Medium | Low | Total | Notes |
|-------|----------|------|--------|-----|-------|-------|
| Backend | 0 | 0 | 2 | 0 | **2** | 2 docker/docker CVEs, no upstream fix |
| Frontend | 0 | 0 | 1 | 0 | **1** | 1 busybox CVE, cannot remove from Alpine |
| **Total** | **0** | **0** | **3** | **0** | **3** | All unfixable, tracked for re-evaluation |

### Subchart images

| Image | Tag | Status |
|-------|-----|--------|
| PostgreSQL | `16.13` (was `16`) | Pinned to latest patch |
| Redis | `7.4.8` (was `7`) | Pinned to latest patch |

### CI gates

- `fail-build: true` with `severity-cutoff: critical` on application image scans
- Subchart scans informational (upstream images, not build-controlled)
- SARIF uploaded for all four images (backend, frontend, PostgreSQL, Redis)

### Automation

- Dependabot: 5 ecosystems, weekly schedule, already generating PRs
- Troubleshoot monitor: weekly cron, auto-creates issues on new releases

### Remaining unfixable CVEs (3)

| CVE | Severity | Package | Image | Reason |
|-----|----------|---------|-------|--------|
| GHSA-x744-4wpc-v9h2 | High* | docker/docker | Backend | No upstream fix (Moby AuthZ bypass) |
| GHSA-pxq6-2prw-chj9 | Medium | docker/docker | Backend | No upstream fix (plugin privilege off-by-one) |
| CVE-2025-60876 | Medium | busybox | Frontend | Cannot remove from Alpine |

*Reclassified: this CVE is in a transitive dependency of the Troubleshoot binary and is not exercisable via the FirstResponse application. The `support-bundle` binary does not use Docker AuthZ plugins. Risk accepted with documentation.

---

## 9. Ongoing Maintenance

To prevent regression, the following maintenance cadence is recommended:

### Weekly

- **Review and merge Dependabot PRs.** Dependabot is already generating PRs for Go, npm, Docker, and GitHub Actions. These should be reviewed weekly to keep dependencies current. As of this writing, 9 Dependabot PRs are open.
- **Monitor Troubleshoot version monitor issues.** When a new Troubleshoot release is available, the monitor workflow creates an issue. Prioritize these if the release includes Go toolchain upgrades.

### After each release

- **Check Replicated Vendor Portal Security Center.** The Vendor Portal scans all images in promoted releases and provides an independent view of the security posture.

### Quarterly

- **Re-evaluate unfixable CVEs.** Check whether upstream fixes have shipped for the 3 remaining CVEs (2 docker/docker, 1 busybox). If fixes are available, create PRs to upgrade.
- **Review base image choices.** Evaluate whether newer base image variants (e.g., future Alpine releases, alternative distroless images) would further reduce attack surface.

### On-demand

- **When Grype fails a PR build:** Investigate immediately. A Critical CVE blocking the build means a new vulnerability has been introduced -- do not disable the gate. Upgrade the affected dependency or, if no fix exists, document the exception and adjust the gate threshold temporarily with a tracking issue for follow-up.

---

## References

- **Epic:** [#161 -- Achieve zero CVEs across all container images](https://github.com/replicated-collab/FirstResponse/issues/161)
- **Baseline audit:** [docs/cve-audit-report.md](https://github.com/replicated-collab/FirstResponse/blob/main/docs/cve-audit-report.md) ([PR #169](https://github.com/replicated-collab/FirstResponse/pull/169))
- **Grype scanner:** [anchore/grype](https://github.com/anchore/grype)
- **Troubleshoot:** [replicatedhq/troubleshoot](https://github.com/replicatedhq/troubleshoot)
- **Replicated Security Center:** [docs.replicated.com/vendor/security-center-overview](https://docs.replicated.com/vendor/security-center-overview)
