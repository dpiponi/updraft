# DECISIONS.md

This file records intentional policy decisions so they do not have to be re-derived or re-debated.

## Launch Behavior

* If launched **without arguments**, Updraft restores the full previous session (all windows).
* If launched with a **PDF path argument**, Updraft restores **all saved windows for that document only**.
* CLI launch never restores unrelated documents.

## Session Saving Policy

* Session state is saved:

  * Debounced on navigation or zoom changes
  * When a window is closed (unless quitting)
  * Once at quit, *before* windows are closed
* During application termination, window-close-triggered saves are suppressed to avoid overwriting session state with zero windows.

## Window Restoration

* Window **frame** (screen coordinates) is restored using `setFrame`, not `contentRect`.
* If no saved frame exists, window is sized to the PDF page and centered.

## Multiple Windows per Document

* A document may have multiple windows open simultaneously.
* Each window has its own independent page position, zoom, and frame.
* All such windows are persisted and restored.

## Link Handling

* Clicking a link navigates in-place.
* Right-click → "Open Link in New Window" spawns a new window:

  * On the link destination
  * With matching zoom (scaleFactor)
  * Window sized to the destination page at that zoom

## CLI vs Session Priority

* CLI intent is explicit and takes priority over session restore scope.
* CLI does *not* imply "fresh state"; it implies "restore state for this document".

