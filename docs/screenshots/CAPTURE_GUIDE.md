# Screenshot Capture Guide

This is the shot list for the README. Save each image into this folder with the **exact filename** listed - the README already references these paths, so screenshots appear automatically once the files exist.

## General tips

- **Capture a window cleanly:** `Cmd-Shift-4`, then press `Space` to switch to window-capture mode, then click the app window. macOS captures it with the rounded corners and a soft shadow (looks great in a README). Files land on your Desktop as `Screenshot ...png`.
- **Capture a region (for crops):** `Cmd-Shift-4`, then drag a rectangle. Use this for the filter bar, the Labels menu, and the detail pane close-ups.
- **Retina note:** screenshots come out at 2x. That's fine - GitHub scales them down and they stay crisp. The `width=` in the README controls display size.
- **Before you start:** pick a moment when you have a nice spread of sessions across several sources and projects, and at least one starred session. If anything shows a real client/repo name you'd rather not publish, rename or filter it out first.
- **Consistency:** use the same window size and light/dark mode across all shots. Light mode usually reads best on GitHub, but pick one and stick with it.
- Rename the captured file to the target filename below and drop it in this folder (`docs/screenshots/`).

---

## Required shots (the core set)

### `01-hero.png` - Full app window
**The most important image.** Sits at the very top of the README.

- Full main window: filter bar + session list on the left, a **selected** session showing its detail pane on the right.
- Pick a session with rich detail (has a plan and transcript, real metadata, a first-message preview).
- Make sure a few different source icons are visible in the list so the "everything in one place" story lands.
- Capture the whole window (window-capture mode). Target display width ~900px.

### `02-search-matches.png` - Full-text search with match pills
Shows the killer feature: deep transcript/plan search.

- Type a query into the toolbar search that hits transcript/plan text, e.g. `transcript:"..."` with a phrase you know appears in a few sessions.
- Frame so the **search field (with the query visible)** and several **cards showing the blue "N transcript matches" / green "N plan matches" pills and snippet lines** are all in view.
- Full window is fine, or crop to toolbar + list. Target width ~900px.

### `03-filters.png` - Filter bar + autocomplete popover
- Open the **Project** filter so its autocomplete popover is visible (the list with per-project "N sessions" counts). Alternatively open the **Source** menu.
- Crop to just the left filter bar plus the open popover (region capture). Target width ~560px.

### `04-labels-menu.png` - Labels dropdown
- Click the **Labels** button next to the search field so the dropdown is open, showing the "Field labels" hints and "Examples" section.
- Region-capture the search field + open menu. Target width ~560px.

### `05-detail-pane.png` - Detail pane close-up
- Select a session and region-capture just the **right detail pane**: the title with star + pencil, the action buttons (Resume.../Open in..., New Chat, Transcript, Open Plan), the Metadata rows with copy/exclude buttons, and the first-message previews.
- Target width ~620px.

### `06-transcript-viewer.png` - Transcript viewer with Find
- Open a transcript (**Transcript** button), press `Cmd-F`, and type a term that matches several times.
- Frame so the **Find bar**, the **"Message N of M"** indicator, highlighted matches, and ideally a collapsed "N internal events" group are all visible.
- Capture the whole viewer window. Target width ~820px.

### `07-plan-viewer.png` - Plan viewer with Find
- Open a plan (**Open Plan** button) on a session that has a good markdown plan.
- Optionally press `Cmd-F` and search so the **"Section N of M"** indicator shows.
- Capture the whole viewer window. Target width ~820px.

---

## Bonus shots (nice to have, referenced in README)

### `08-in-progress.png` - In-progress session + resume confirmation
- Find a Copilot CLI or Claude Code CLI session that's currently running (orange **"In Progress"** pill on the card / detail pane).
- Click its resume button so the **"Session Currently Active"** confirmation dialog appears, then capture the window with the dialog on top.
- If you can't get a live in-progress session, just capture a card/detail showing the "In Progress" pill. Target width ~820px.

### `09-settings-indexes.png` - Settings → Indexes
- Open Settings (`Cmd-,`) → **Indexes**.
- Show the Projects/Branches/Sessions segmented scope switcher, the search field, the All/Included/Excluded filter menu, and a list of items with Included/Excluded pills.
- Capture the whole settings window. Target width ~820px.

### `10-settings-general.png` - Settings → General *(optional, not yet in README)*
- Open Settings (`Cmd-,`) → **General**: Launch at Login, Newton repos path, Auto Refresh options.
- Capture the whole settings window. Target width ~820px.
- If you want this in the README, tell me and I'll add a placeholder for it.

---

## Filename checklist

```
docs/screenshots/
  01-hero.png              (required)
  02-search-matches.png    (required)
  03-filters.png           (required)
  04-labels-menu.png       (required)
  05-detail-pane.png       (required)
  06-transcript-viewer.png (required)
  07-plan-viewer.png       (required)
  08-in-progress.png       (bonus)
  09-settings-indexes.png  (bonus)
  10-settings-general.png  (optional, ask to add)
```

Once these are dropped in, the README renders end to end. Send me the first one or two and I'll sanity-check framing/crops and adjust `width=` or captions if needed.
