# What DDCC does

DDCC has three main views.

**Caches** finds known developer caches, build output, logs, browser caches,
device support files, and app support data. These results are grouped into
categories and tiers, so you can see what can be rebuilt, what may need a
download, and what may contain data you should inspect first.

**Files** searches for large, long-unmodified files and bundles outside the
cache categories. This is useful for old exports, disk images, archives, and
virtual machines. Files results are chosen one at a time and can only be moved
to the Trash.

**Uninstall** lists every app identity on the machine — installed, or already
gone — with the footprint DDCC can attribute to it from evidence: sandbox
containers, shelves, entitlements, Homebrew declarations, and receipts. See
[The Uninstall view](uninstall-view.html).

Caches and Files avoid reporting the same space twice: cache paths stay in
Caches, and large files outside those paths show up in Files. Uninstall is a
different kind of list — one row per app rather than one row per path — and
can legitimately show some of the same bytes Caches already does: emptying an
app's cache and removing the app entirely are different actions on the same
data. DDCC never adds an Uninstall total to a Caches total, so that overlap is
never counted twice in one number.

DDCC reports allocated disk space it can identify. It does not claim to account
for every byte on the disk. Small files outside the cache categories, cloud-only
files, purgeable APFS space, snapshots, and folders macOS refuses to read may
not appear in any view.

DDCC does not clean memory, remove malware, update apps, scan cloud storage, or
delete files automatically. It focuses on local disk space.
