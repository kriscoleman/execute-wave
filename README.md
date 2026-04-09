---
name: execute-wave
description: Run the outer planning and execution loop for a new epic or phase. Decomposes the epic into independent issues, slings to polecats in parallel, monitors convergence, and closes the wave when all beads land. Use when Mayor receives a new epic bead or the user drops a phase description.
---

# execute-wave

Run the outer loop for a new Gas Town wave. One invocation per epic or phase.

## When to invoke

Invoke this skill when:
- A new epic bead lands on your hook
- The user describes a new phase of work
- You are about to start decomposing a large piece of work

Do NOT invoke when handling individual issues, code reviews, or escalations — those are inner loop work.

## Step 1 — Epic Intake

Read the epic. Extract and write down:
- **Goal**: one sentence, what shipped when this wave is done
- **Requirements**: the table-stakes list — what must be true for the wave to close
- **Scope boundary**: what is explicitly OUT of this wave
- **Sequencing constraints**: any explicit "X must land before Y"

If the epic is vague, ask one clarifying question before proceeding. Do not decompose a vague epic.

## Step 2 — Decomposition

Break the phase into issues. For EACH issue, apply the independence check before filing:

**Independence check** (all three must be true):
1. A single agent can complete it without reading another in-flight issue's working files
2. No shared mutable state with sibling issues (no same-file edits, no shared DB migrations, no shared config keys)
3. Deliverable is a single PR — one branch, reviewable in isolation

If an issue FAILS the check:
- If it can be split → split it into two independent issues
- If it cannot be split → mark it as sequentially dependent and note which issue it must follow

**Issue sizing**: each issue should be completable in one focused session. If you can't describe the PR in one sentence, the issue is too large.

**File each issue:**
```bash
bd create --title="<verb> <what>" \
  --description="Why this issue exists and what needs to be done" \
  --type=feature|bug|task \
  --priority=2
```

## Step 3 — Sling in Parallel

Sling all independent issues to available polecats simultaneously. Do NOT wait for one to finish before slinging the next — that defeats the purpose.

```bash
gt sling <bead-id> <rig>   # repeat for each independent issue
```

Record the wave: note which bead IDs belong to this wave so you can track convergence. Pin a wisp or add a note to the epic bead.

For sequentially dependent issues: sling the blocking issue first. When it merges, sling the dependent issue immediately.

## Step 4 — Monitor Convergence

Check wave state periodically:
```bash
bd list --status=in_progress   # what's in flight
bd blocked                      # anything stuck
gh pr list --repo <repo>        # PR status
```

**Handle escalations from inner loops:**
- CI failure → read the failure, diagnose, decide: fix directly (if trivial) or sling a fix bead
- Review `REQUEST CHANGES` → read the feedback, decide: clarify to the polecat or sling a revision bead
- Polecat hits ambiguity → answer the question directly via `gt nudge`

Do NOT re-sling the same issue to a new polecat without first understanding why the original failed.

## Step 5 — Merge and Close

When a PR is green (CI passing, review approved):
```bash
gh pr merge <number> --squash --repo <repo>
bd close <bead-id>
```

When ALL beads in the wave are merged:
1. Close the wave epic bead: `bd close <epic-id> --reason="Wave complete: all N issues merged"`
2. Surface the next phase if one exists: check the parent epic for the next meso-level item
3. Nudge relevant witnesses: `gt nudge <rig>/witness "Wave N complete, N PRs merged"`

## Anti-patterns

- **Do not do the coding yourself** unless the fix is trivially one-line and slinging would require waking a new polecat. Your context window is the scarcest resource.
- **Do not batch-merge without CI**. Every PR must be green before merge.
- **Do not decompose without the independence check**. Two polecats editing the same file = merge conflict = wasted work.
- **Do not skip the wave-close step**. Open epic beads with all sub-issues closed is noise in `bd list`.
