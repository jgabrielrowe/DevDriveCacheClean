# The Files view controls

The Files view searches for large, long-unmodified files outside the cache categories. It only moves selected items to the Trash.

<a name="files-mode"></a>

### The Files view

The Files view searches for large, long-unmodified files and bundles outside DDCC's cache categories. Review each result yourself; files from this view can only be moved to the Trash.

<a name="files-find"></a>

### Find

Searches the selected folder for files and bundles that pass both filters. DDCC skips ~/Library and paths already covered by the Caches view.

<a name="files-stop"></a>

### Stop

Stops the current Files search and clears its in-progress results. Run Find again when you want a complete list.

<a name="files-root"></a>

### Search folder

The default is your home directory. If you choose a folder inside ~/Library, the Files view may find nothing because library paths are handled by the Caches view.

<a name="files-size-threshold"></a>

### Minimum size

A file must meet both the size and age filters to appear. Choose Any size when you want to filter only by age.

<a name="files-age-threshold"></a>

### Unmodified for

Uses the modification date, not the last time you opened the file. A document you read often but never edit can still appear as unmodified.

<a name="files-row-checkbox"></a>

### Selecting a row

Files are never selected automatically, and there is no select-all in this view. Choose each file or bundle by hand.

<a name="files-deselect-all"></a>

### Deselect all

Clears every selected row, including rows a filter is currently hiding.

<a name="files-trash"></a>

### Move to Trash

Moves the selected files and bundles to the Trash, where they can be put back. The Files view does not offer permanent deletion.

<a name="files-reveal"></a>

### Show in Finder

Opens a Finder window with this file selected so you can inspect it before moving it.

<a name="files-partial-size"></a>

### Sizes marked with a plus

A size with a trailing plus is a lower bound. DDCC measured what it could read, but the real size may be larger.