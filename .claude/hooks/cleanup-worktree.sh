#!/bin/bash

HOOK_INPUT=$(cat)
WORKTREE_PATH=$(echo "$HOOK_INPUT" | jq -r '.worktree_path')

GIT_REPO="/Users/kris/gt_lab/FirstResponse/mayor/rig"

cd "$GIT_REPO"
git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
