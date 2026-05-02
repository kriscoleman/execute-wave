# Design Spec: Private Comments with Unified Timeline

**Issue:** replicated-collab/FirstResponse#215
**Date:** 2026-04-23
**Status:** Draft

## Overview

Add internal-only annotations to GitHub issues within FirstResponse. Private comments are stored locally in PostgreSQL and never synced to GitHub. They appear alongside GitHub comments in a unified chronological timeline on the issue detail page, giving support teams a single view of all conversation context — public and private.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Visibility | All org members | Support teams need shared context, not personal silos |
| Rendering | GitHub-flavored markdown | Matches GitHub comment feel, supports code blocks and links |
| Placement | Below issue body, unified timeline | Natural scroll flow, single view for all activity |
| Editing | Edit with revision history | Flexibility + accountability — previous versions preserved |
| Data merge | Server-side in `/timeline` endpoint | Single API call, no client-side assembly |
| Unread tracking | Per-user `last_read_at` timestamp | Lightweight, no per-comment granularity needed |

## Data Model

### Migration: `005_private_comments.up.sql`

**Table: `private_comments`**

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | BIGSERIAL | PRIMARY KEY |
| `issue_id` | BIGINT NOT NULL | GitHub issue ID (globally unique, survives cache eviction) |
| `org_login` | TEXT NOT NULL | Org scope |
| `repo_name` | TEXT NOT NULL | Repo scope |
| `issue_number` | INTEGER NOT NULL | For URL routing |
| `author_login` | TEXT NOT NULL | Who wrote it |
| `body` | TEXT NOT NULL | Markdown content |
| `created_at` | TIMESTAMPTZ | DEFAULT NOW() |
| `updated_at` | TIMESTAMPTZ | DEFAULT NOW() |

Indexes: `(issue_id)`, `(org_login, repo_name, issue_number)`

**Table: `private_comment_revisions`**

| Column | Type | Constraints |
|--------|------|-------------|
| `id` | BIGSERIAL | PRIMARY KEY |
| `comment_id` | BIGINT NOT NULL | REFERENCES private_comments(id) ON DELETE CASCADE |
| `body` | TEXT NOT NULL | Previous version of the comment |
| `edited_at` | TIMESTAMPTZ | DEFAULT NOW() |

Index: `(comment_id)`

**Table: `comment_read_status`**

| Column | Type | Constraints |
|--------|------|-------------|
| `user_login` | TEXT NOT NULL | Who read it |
| `issue_id` | BIGINT NOT NULL | Which issue |
| `last_read_at` | TIMESTAMPTZ NOT NULL | When they last viewed the timeline |

Primary key: `(user_login, issue_id)`

### Schema note on `issues` table

Add a `github_comment_count` INTEGER column to the existing `issues` table. Updated by `issue_comment` webhooks (increment on `created`, decrement on `deleted`). This avoids a GitHub API call to get the count for the issue list badges.

## API Design

### Unified Timeline

```
GET /api/v1/issues/{org}/{repo}/{number}/timeline?source=all|github|internal
```

**Behavior:**
1. Fetch GitHub comments for the issue (cached in Redis, 5min TTL)
2. Query private comments from PostgreSQL
3. Merge into a single array sorted by `created_at`
4. Upsert `comment_read_status` for the current user (marks as read)
5. Return unified list

**Response:**
```json
{
  "items": [
    {
      "source": "github",
      "id": 123456,
      "author": "customer-jane",
      "authorAvatar": "https://...",
      "body": "This is blocking our production...",
      "createdAt": "2026-04-20T10:00:00Z",
      "updatedAt": "2026-04-20T10:00:00Z"
    },
    {
      "source": "internal",
      "id": 1,
      "author": "kris",
      "authorAvatar": "https://...",
      "body": "Same root cause as Acme ticket...",
      "createdAt": "2026-04-20T11:00:00Z",
      "updatedAt": "2026-04-20T12:00:00Z",
      "edited": true,
      "revisionCount": 1
    }
  ]
}
```

### Private Comment CRUD

```
POST   /api/v1/issues/{org}/{repo}/{number}/comments
PUT    /api/v1/issues/{org}/{repo}/{number}/comments/{id}
DELETE /api/v1/issues/{org}/{repo}/{number}/comments/{id}
GET    /api/v1/issues/{org}/{repo}/{number}/comments/{id}/revisions
```

**Create** — Any authenticated org member. Body: `{ "body": "markdown text" }`

**Edit** — Author only. Before updating the main row, insert the current body into `private_comment_revisions`. Body: `{ "body": "updated text" }`

**Delete** — Author only. Cascades to revisions.

**Revisions** — Returns array of `{ body, editedAt }` ordered by `edited_at DESC`.

### Issue List Augmentation

The existing `GET /api/v1/issues` response adds two fields per issue:

```json
{
  "commentCount": 5,
  "hasUnread": true
}
```

- `commentCount` = `github_comment_count` (from issues table) + COUNT of private_comments for the issue
- `hasUnread` = true when any comment (GitHub or internal) has `created_at > last_read_at` for the current user, or `last_read_at` is NULL (never opened)

Computed via LEFT JOIN on `comment_read_status` and a subquery on `private_comments` in the existing list query.

## Frontend Architecture

### New Components

| Component | File | Purpose |
|-----------|------|---------|
| `ActivityTimeline` | `components/ActivityTimeline.tsx` | Fetches `/timeline`, renders sorted entries, filter bar |
| `TimelineEntry` | `components/TimelineEntry.tsx` | Single entry — GitHub (gray) or internal (amber) styling |
| `ComposeNote` | `components/ComposeNote.tsx` | Markdown textarea + "Post Note" button, amber themed |
| `RevisionHistory` | `components/RevisionHistory.tsx` | Expandable panel showing edit history |
| `CommentBadge` | `components/CommentBadge.tsx` | Reusable badge showing count + unread dot |

### Modified Components

| Component | Change |
|-----------|--------|
| `IssueDetailPage.tsx` | Add `ActivityTimeline` below labels section |
| `IssueTable.tsx` | Add `CommentBadge` to each row |
| `KanbanCard.tsx` | Add `CommentBadge` to card footer |
| `types/index.ts` | Add `TimelineEntry`, `PrivateComment`, `CommentBadge` types; extend `Issue` with `commentCount`, `hasUnread` |
| `api/client.ts` | Add timeline, comment CRUD, and revision API methods |

### Visual Design

**Timeline entries:**
- GitHub comments: neutral gray badge, gray avatar border, read-only
- Internal notes: amber badge (`🔒 Internal`), amber left-border gradient, Edit/Delete for author
- "(edited)" indicator on modified notes, clickable to expand revision history

**Filter bar** (top of timeline):
- Three toggles: All | GitHub only | Internal only
- Passes `?source=` param, refetches via React Query

**Compose area** (bottom of timeline):
- Amber-themed section with `2px solid #d97706` top border
- Markdown textarea with placeholder "Write a private note (supports GitHub-flavored markdown)..."
- "Only visible to your team" helper text
- "Post Note" button

**Comment badges** (issue list + kanban):
- Amber pill with 💬 icon + count when comments exist
- Orange dot overlay when unread
- Gray pill when all read
- No badge when no comments

### Markdown Rendering

- `react-markdown` with `remark-gfm` plugin for GFM support
- GitHub comments: sanitize HTML via `DOMPurify` before rendering (untrusted content)
- Internal notes: render markdown directly (trusted — authored by org members)

## Backend Architecture

### New Files

| File | Purpose |
|------|---------|
| `backend/migrations/005_private_comments.up.sql` | Schema for all 3 tables + issues column |
| `backend/migrations/005_private_comments.down.sql` | Rollback |
| `backend/internal/api/timeline.go` | Timeline endpoint — merges GitHub + private comments |
| `backend/internal/api/private_comments.go` | CRUD handlers for private comments |
| `backend/internal/db/private_comments.go` | DB query helpers |

### Modified Files

| File | Change |
|------|--------|
| `backend/internal/api/router.go` | Register new routes |
| `backend/internal/api/handler.go` | Add `commentCount` and `hasUnread` to issue list response; update `issue_comment` webhook to increment `github_comment_count` |

### GitHub Comment Caching

The `/timeline` endpoint fetches GitHub comments via the existing `ListIssueComments()` client method. Response is cached in Redis with key `github-comments:{org}:{repo}:{number}` and 5-minute TTL. Cache is invalidated when an `issue_comment` webhook arrives for the issue.

### Webhook Changes

The existing `handleIssueCommentEvent` (which already upserts issue `updated_at`) additionally:
- Increments/decrements `github_comment_count` on the `issues` row
- Invalidates the Redis GitHub comments cache for the issue

## Error Handling

| Scenario | Behavior |
|----------|----------|
| GitHub API rate limited during timeline fetch | Return private comments only, show "GitHub comments temporarily unavailable" banner |
| GitHub API timeout | Same — degrade gracefully, internal notes always available |
| User edits comment they don't own | 403 Forbidden |
| Comment on issue not in user's org | 403 Forbidden |
| Issue not in DB (never synced) | Timeline still works — fetches GitHub comments live, private comments will be empty |

## Testing Strategy

- **Backend unit tests**: CRUD operations, revision creation on edit, read status upsert, comment count computation
- **API integration tests**: Timeline merge ordering, filter param, auth checks (edit/delete author-only)
- **Frontend**: Component renders for each timeline entry type, badge states (unread/read/none), compose flow
- **Manual UAT**: Create internal notes, verify they don't appear on GitHub, verify edit history, verify unread badges clear on open

## Decomposition (Suggested Sub-Issues)

| # | Issue | Depends On | Scope |
|---|-------|------------|-------|
| 1 | DB migration + private comment CRUD API | — | Backend |
| 2 | Timeline endpoint (merge GitHub + private) | #1 | Backend |
| 3 | `ActivityTimeline` + `TimelineEntry` + `ComposeNote` UI | #2 | Frontend |
| 4 | Edit with revision history (API + UI) | #1 | Full-stack |
| 5 | Comment badges on issue list + kanban cards | #2 | Full-stack |
| 6 | Unread tracking (read status table + badges) | #5 | Full-stack |

Issues 1-3 are the critical path. Issues 4-6 can follow in parallel after #2 lands.
