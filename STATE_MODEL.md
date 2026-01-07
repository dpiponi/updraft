# STATE_MODEL.md

## Persisted State Overview

Updraft persists state at the **window level**, grouped by document identity.

### Document Identity

A document is identified by:

* Security-scoped bookmark data (preferred)
* File fingerprint:

  * File size
  * Modification timestamp

This allows state to survive renames and moves, and degrade gracefully if the file changes.

## WindowState

Each open window persists:

* DocumentKey (bookmark + fingerprint)
* View state
* Window frame (screen coordinates)

## DocumentViewState

Per window:

* `pageIndex` (0-based)
* Optional `pointInPage` (page-local coordinates)
* Zoom state:

  * `usesAutoScale` OR
  * explicit `scaleFactor`

## Restore Semantics

* If fingerprint matches:

  * Restore page
  * Restore point-in-page
  * Restore zoom mode
* If fingerprint differs:

  * Clamp page index
  * Ignore fine-grained position
  * Preserve zoom

## Saving Strategy

* StateStore serializes the full session to UserDefaults as JSON.
* No partial writes; each save overwrites the previous snapshot.
* Session restore is best-effort; failures to resolve a document skip that window only.

## Invariants

* Session restore must never crash on missing or changed files.
* A valid window list at quit must always be restorable.
* Window frame restoration must not be overridden by centering logic.

