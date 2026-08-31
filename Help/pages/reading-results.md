# Reading scan results

The Caches list shows one row for each path DDCC found.

The icon at the left shows whether the row can be selected now:

- An empty circle means the item can be selected.
- A checked circle means it is selected.
- A lock means the category must be enabled before the item can be selected.
- A warning triangle means the item is destructive and must be opted into one
  item at a time.
- A minus sign means DDCC can show the size, but cannot remove the path.

The **Size** column shows allocated disk space. A size ending in `+` means DDCC
could not read everything inside that item, so the real size may be larger.

The **Modified** column is a useful clue, not a decision by itself. Some caches
change often; some large files stay unchanged for years because they are
finished artifacts.

Select a row to see its full path and detail actions. **Reveal in Finder** shows
the item without changing it. **Open in Terminal** opens a Terminal window at
that path.

After a failed removal, DDCC leaves the failed row in the list and shows the
first failure reason at the bottom of the window. The row remains selected so
you can retry or inspect it.
