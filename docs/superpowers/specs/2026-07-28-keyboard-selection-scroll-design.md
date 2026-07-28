# Keyboard Selection Scroll Design

## Problem

The history panel updates `AppModel.selectedItemID` when the user presses the
Up or Down arrow key. The visible history list is a `ScrollView` containing a
`LazyVStack`, but its rows are not programmatic scroll targets and the scroll
view does not react to selection changes. As a result, keyboard selection can
move beyond the visible rows while the scroll position remains unchanged.

## Desired Behavior

- Keep the keyboard-selected history row fully visible.
- Scroll only when needed, and only by the minimum distance required.
- Preserve the existing selection, search, refresh, hover, click, and paste
  behavior.
- Continue supporting the package's macOS 13 deployment target.

## Design

Wrap the existing history `ScrollView` in a `ScrollViewReader`. Give each row
its existing stable `ClipboardItem.id` as its SwiftUI view identifier. Observe
changes to `model.selectedItemID` inside the reader and call
`ScrollViewProxy.scrollTo(_:)` without an anchor for a valid selected item.

SwiftUI documents that an omitted anchor scrolls the minimum amount required
to make the identified view wholly visible. This provides native list-like
following without recentering the row on every key press.

The keyboard router and `AppModel.moveSelection(delta:)` remain unchanged.
Selection continues to have one source of truth, and the view merely reflects
that state by keeping the selected row visible.

## Edge Cases

- Empty history: no row and no scroll request.
- Selection removed by refresh or search: `AppModel.reconcileSelection()`
  selects the first valid result; the list scrolls it into view.
- Stale or unknown selection ID: ignore the scroll request.
- Repeated Up at the first row or Down at the last row: the selected ID does
  not change, so no unnecessary scrolling occurs.
- Mouse scrolling remains unrestricted; the list only repositions after the
  selected ID changes.

## Testing

Add a regression test for resolving a valid selected ID into a scroll target
and rejecting nil or stale selections. Then connect that tested resolution to
the `ScrollViewReader` listener.

Verification:

1. Run the focused LocalClip test runner and confirm the new regression test
   fails before the implementation and passes afterward.
2. Run the complete test runner.
3. Build the `LocalClip` release product to validate the SwiftUI integration
   against the macOS 13 deployment target.
