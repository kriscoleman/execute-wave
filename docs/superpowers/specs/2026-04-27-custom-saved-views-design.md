# Design Spec: Custom Saved Views — Replace Hardcoded Support Queue

**Repo:** replicated-collab/FirstResponse
**Issue:** #139
**Date:** 2026-04-27
**Status:** Draft

## Problem

The support queue views are hardcoded to one team's label conventions (`status::open`, `status::pending`, `kind::inbound-escalation`, etc.). Other GitHub users installing FirstResponse get views that match nothing. Users need to create, edit, delete, and import their own views.

## Design Decisions

| Decision | Choice |
|----------|--------|
| View ownership | Personal + shared (per-org) |
| Default views | None — clean slate, users build their own |
| Hardcoded views | Removed entirely (`supportQueueViews.ts`, `useSeedViews.ts` deleted) |
| GitHub URL import | Dedicated "Import from GitHub URL" button with filter preview |
| Storage | PostgreSQL `saved_views` table (already exists, needs columns) |

## Data Model

### Migration: update `saved_views`

```sql
ALTER TABLE saved_views ADD COLUMN owner_login TEXT NOT NULL;
ALTER TABLE saved_views ADD COLUMN org_login TEXT;
ALTER TABLE saved_views ADD COLUMN is_shared BOOLEAN DEFAULT false;
ALTER TABLE saved_views ADD COLUMN sort_order INTEGER DEFAULT 0;

CREATE INDEX idx_saved_views_owner ON saved_views(owner_login);
CREATE INDEX idx_saved_views_org ON saved_views(org_login);
```

- `owner_login` — who created it
- `org_login` — NULL = personal view, set = shared org view
- `is_shared` — false = personal, true = shared within org
- `sort_order` — user-defined sidebar ordering

### SavedView type (updated)

```typescript
interface SavedView {
  id: number;
  name: string;
  filters: IssueFilters;
  ownerLogin: string;
  orgLogin: string | null;
  isShared: boolean;
  sortOrder: number;
  createdAt: string;
  updatedAt: string;
}
```

## API

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/v1/views` | List user's personal views + shared views for their orgs |
| `POST` | `/api/v1/views` | Create a view (personal or shared) |
| `PUT` | `/api/v1/views/{id}` | Update (owner only, or any org member for shared) |
| `DELETE` | `/api/v1/views/{id}` | Delete (owner only) |
| `POST` | `/api/v1/views/import-url` | Parse GitHub search URL → return extracted filters (preview) |
| `PUT` | `/api/v1/views/reorder` | Update sort_order for multiple views at once |

### GET /api/v1/views response

```json
{
  "personal": [
    {"id": 1, "name": "My escalations", "filters": {...}, "sortOrder": 0}
  ],
  "shared": [
    {"id": 5, "name": "Team open issues", "filters": {...}, "orgLogin": "replicated-collab", "ownerLogin": "kris", "sortOrder": 0}
  ]
}
```

### POST /api/v1/views/import-url

Request: `{"url": "https://github.com/search?q=org%3Areplicated-collab+label%3Akind..."}`

Response (preview, not saved):
```json
{
  "name": "Suggested: replicated-collab open issues",
  "filters": {
    "org": "replicated-collab",
    "labels": "kind::inbound-escalation",
    "state": "open",
    "excludeLabels": "status::closed,status::pending,status::awaiting-confirmation",
    "excludeRepos": "replicated-collab/superci-replicated,replicated-collab/inbound-escalation-catchall"
  }
}
```

## GitHub URL Parser

Parses `github.com/search?q=...` URLs. The `q` parameter is URL-decoded then split on spaces.

| GitHub query token | Maps to IssueFilters |
|-------------------|---------------------|
| `org:X` | `org: "X"` |
| `label:X` | `labels` (comma-join multiples) |
| `-label:X` | `excludeLabels` (comma-join multiples) |
| `assignee:X` | `assignee: "X"` |
| `is:open` | `state: "open"` |
| `is:closed` | `state: "closed"` |
| `-repo:X` | `excludeRepos` (comma-join multiples) |
| `repo:X` | (add to org filter context) |
| `is:issue` | ignored (default) |
| `is:pr` | (flag for future PR view support) |
| `commenter:X` | `commenter: "X"` |
| `no:assignee` | `unassigned: true` |

Parser is a **frontend utility** — decodes URL, extracts `q` param, tokenizes, maps each token to a filter field. No backend needed for parsing (the import-url endpoint is a convenience wrapper for server-side parsing if needed).

## Frontend

### Files to remove

- `frontend/src/data/supportQueueViews.ts` — deleted
- `frontend/src/hooks/useSeedViews.ts` — deleted
- All references to `supportQueueViews` in Sidebar.tsx
- Hardcoded "SUPPORT QUEUE" and "PRODUCTS" sidebar sections

### New components

**CreateViewDialog** — stepped form:
1. Name the view
2. Pick filters: org dropdown, labels input, assignee, state toggle, exclude labels, exclude repos
3. Personal or Shared toggle (shared shows org picker)
4. Preview: shows count of matching issues with current filters
5. Save button

**ImportFromURLDialog** — focused import flow:
1. Text input: "Paste a GitHub search URL"
2. On paste: parse URL → show extracted filters in a preview table
3. Name input (pre-filled with suggested name from parser)
4. Personal/Shared toggle
5. Save button

**EditViewDialog** — same as CreateViewDialog but pre-filled with existing view's data.

### Sidebar changes

Replace "SUPPORT QUEUE" + "SAVED VIEWS" + "PRODUCTS" with a single **"VIEWS"** section:

```
VIEWS
  + Create View    📋 Import URL
  ─────────────────────────
  My escalations           (12)
  Unassigned open          (5)
  ─────────────────────────
  SHARED — replicated-collab
  Team open issues         (30)
  Pending review           (3)
```

- Personal views first, then shared views grouped by org
- "+" button opens CreateViewDialog
- "Import URL" button opens ImportFromURLDialog
- Each view: click to navigate, kebab menu (⋮) for Edit/Delete
- Counts from existing `useViewCounts` (works with dynamic views)
- Drag-to-reorder or up/down arrows for sort_order
- Empty state: "No views yet. Create your first view or import from a GitHub search URL."

### Files unchanged

- `IssueFilters` type — unchanged
- `useViewCounts` hook — works with dynamic views (already accepts arbitrary filter definitions)
- `ViewPage.tsx` — unchanged (loads view by ID, applies filters)
- `OrgFilterPopover` — still applies globally on top of view filters

## Backend

### Files to modify

- `backend/migrations/` — new migration for saved_views columns
- `backend/internal/api/handler.go` — replace stub ListViews/CreateView with real DB CRUD
- `backend/internal/api/router.go` — add PUT/DELETE routes + import-url + reorder
- `backend/internal/db/` — new `saved_views.go` with query helpers

### DB helpers

```go
ListViewsForUser(ctx, db, userLogin string, orgLogins []string) (personal []SavedView, shared []SavedView, error)
CreateView(ctx, db, view SavedView) (*SavedView, error)
UpdateView(ctx, db, id int, view SavedView) error
DeleteView(ctx, db, id int, ownerLogin string) error
ReorderViews(ctx, db, ownerLogin string, orders []ViewOrder) error
```

### Auth rules

| Action | Who can do it |
|--------|--------------|
| Create personal view | Any authenticated user |
| Create shared view | Any member of the org |
| Edit personal view | Owner only |
| Edit shared view | Any member of the org |
| Delete any view | Owner only |
| Reorder | User reorders their own sidebar (personal sort_order) |

## Sub-Issues (suggested decomposition)

| # | Issue | Scope |
|---|-------|-------|
| 1 | DB migration + CRUD API | Backend |
| 2 | GitHub URL parser utility | Frontend |
| 3 | CreateViewDialog + EditViewDialog | Frontend |
| 4 | ImportFromURLDialog | Frontend |
| 5 | Sidebar refactor (remove hardcoded, add dynamic views) | Frontend |
| 6 | Remove supportQueueViews.ts + useSeedViews.ts | Cleanup |
