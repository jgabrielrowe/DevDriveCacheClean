# The Files view

Use Files to find large items outside the cache categories: old exports, disk
images, archives, virtual machines, and app bundles.

Choose a search folder, set a minimum size and a minimum age, and press
**Find**. A file must pass both thresholds to appear.

The age filter uses the modification date. That is when a file last changed,
not when you last opened it. A document you read often but never edit may still
appear as unmodified.

`~/Library` is always skipped, along with every directory the Caches view
already covers. If you choose a folder inside `~/Library`, Files may find
nothing.

Files and bundles are never selected automatically, and there is no select-all.
Choose each row by hand. Press the space bar to preview the selected file
without leaving DDCC.

The file detail pane shows the path, size, age, and a Finder reveal action.
Files with a `+` after the size are lower bounds because DDCC could not read
everything inside the item.

Bundles such as `.app`, `.photoslibrary`, and `.sparsebundle` are shown as one
item and moved as one item.

Stopping a Files search discards the in-progress result list. Run **Find**
again when you want a complete list for the current filters.

The individual controls are described under
[The Files view controls](reference-files.html).
