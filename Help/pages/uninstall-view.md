# The Uninstall view

Use Uninstall to see what an app left behind — installed, or already gone —
and remove it. Press **Sweep** to build the list. **Stop** cancels an active
sweep; anything already found stays on screen, marked as incomplete.

Each row is one app identity. Small type below the name says which evidence
DDCC used to attribute anything to it — a sandbox container, a shelf such as
Preferences or Caches, a group entitlement, a Homebrew declaration, an install
receipt, or a native-messaging-host manifest. Nothing is guessed from a
directory's name alone.

Select a row to see the full breakdown. **Reclaimable** lists what DDCC can
remove for this app. **Retained** lists what still belongs to this app but
another installed product also claims — it stays until every claimant is
gone, and its bytes are excluded from the reclaimable total so removing this
app never overstates what came back.

> DDCC also states what it found but will not offer: paths that sit outside
> the folders it is allowed to remove from, and paths inside those folders
> that its safety check refused anyway. Neither is counted toward any size.

**Move to Trash** moves the reclaimable items; nothing is freed until the
Trash is emptied. **Delete Permanently** skips the Trash and cannot be undone
— DDCC asks you to confirm before doing it.

A broken dependency pointer — a manifest or launch agent naming a file that no
longer exists — is proof of deadness on its own, so it appears as its own row
even though it belongs to no app, and can be removed like any other row.

The search field filters the list by app name or bundle identifier, and the
sort picker orders it by size, by how much is reclaimable, or by name. Apps
with nothing to reclaim are not listed.

Below the list, DDCC states which evidence sources were unavailable for this
sweep and how many bytes it found on disk but could not attribute to any app.

**Removing the app itself.** The application bundle is listed alongside its
leftovers and goes in the same action. An app installed for everyone on the Mac
— usually one that arrived as an installer package — belongs to the system
rather than to you, and macOS will not let you move it to the Trash on your
own. DDCC asks Finder to do it, so macOS prompts for Touch ID or your password
and performs the move itself. An app removed that way can only go to the Trash,
never be deleted permanently; the confirmation tells you so rather than
skipping it quietly. The first time this happens, macOS also asks whether DDCC
may control Finder.

**Apps that are running.** A running app is listed with an explanation instead
of a size, because a live app keeps rewriting the files being counted. The pane
offers **Quit** and **Force Quit** — force quitting discards unsaved work, so
it asks first. Sweep again once the app has stopped and its real footprint
appears.

Every source DDCC reads is a local file, and it makes no network connection.
The only subprocess it launches is `/usr/bin/osascript`, and only to ask Finder
to move an app you chose to remove.
