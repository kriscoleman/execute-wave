#!/bin/bash
set -e

# Read hook input from stdin
HOOK_INPUT=$(cat)

WORKTREE_PATH=$(echo "$HOOK_INPUT" | jq -r '.worktree_path')
BRANCH_NAME=$(echo "$HOOK_INPUT" | jq -r '.branch_name // empty')
DETACH=$(echo "$HOOK_INPUT" | jq -r '.detach // "true"')

# The actual git repo (mayor's rig checkout)
GIT_REPO="/Users/kris/gt_lab/FirstResponse/mayor/rig"

cd "$GIT_REPO"

if [ "$DETACH" = "true" ] || [ -z "$BRANCH_NAME" ]; then
  git worktree add --detach "$WORKTREE_PATH" HEAD
else
  git worktree add "$WORKTREE_PATH" "$BRANCH_NAME"
fi

echo "$WORKTREE_PATH"
