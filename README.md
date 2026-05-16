# execute-wave

An [ailloy](https://github.com/ailloy/ailloy) mold for Mayor orchestration of parallel agent execution.

Decomposes epics into independent issues, dispatches them to polecats in parallel, monitors convergence, and closes the wave when all work lands.

## Install

Molds can be cast directly from the GitHub URL — no separate `mold get` step needed.

```bash
# Install globally (recommended — gives all Gas Town agents access)
ailloy cast -g github.com/kriscoleman/execute-wave

# Or install locally to a specific project
ailloy cast github.com/kriscoleman/execute-wave
```

The `-g` flag installs to `~/.claude/skills/` (global), making the skill available to all agents (mayor, polecats). Without `-g`, the skill installs to `.claude/skills/` in the current project directory.

## What it does

The execute-wave skill implements a five-step orchestration loop:

1. **Epic Intake** -- extract goal, requirements, scope boundary, and sequencing constraints
2. **Decomposition** -- break the epic into independent issues, each passing a strict independence check
3. **Sling in Parallel** -- dispatch all independent issues to polecats simultaneously
4. **Monitor Convergence** -- track in-flight work, handle escalations, unblock stuck agents
5. **Merge and Close** -- squash-merge green PRs, close beads, surface the next phase

## When to use

Invoke this skill when:
- A new epic bead lands on your hook
- The user describes a new phase of work
- You are about to start decomposing a large piece of work

Do NOT invoke for individual issues, code reviews, or escalations -- those are inner-loop work.

## Mold structure

```
execute-wave/
  mold.yaml       -- mold metadata
  flux.yaml       -- output configuration
  skills/         -- the execute-wave skill content
  AGENTS.md       -- agent instructions
  README.md       -- this file
```

## License

MIT
