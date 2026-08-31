# How DDCC reports totals

DDCC reports scan totals conservatively.

Each Caches result comes from a known pattern and includes a category, tier, and
size. The category tells you what kind of item it is. The tier tells you how
cautious to be before selecting it.

When DDCC cannot read everything inside an item, it marks the size with a `+`.
That means the displayed number is a lower bound; the real size may be larger.

DDCC does not claim to account for every byte on the disk. Caches reports known
cache and support-data paths. Files reports large, long-unmodified files outside
those paths. A folder full of small files outside both views may not appear.

The Files view reports files and bundles, not rolled-up folder totals. A
directory can therefore consume real space without appearing as one row.

If a scan is stopped or a folder cannot be read, treat the total as incomplete.
