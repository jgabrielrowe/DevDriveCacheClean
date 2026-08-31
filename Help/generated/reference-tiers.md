# The three tiers

Tiers describe the risk of removing an item. They also control how DDCC lets you select it.

<a name="tier-safe"></a>

### Safe

Usually local build output or app cache data. Removing it should only affect the project or app that created it, and it can be rebuilt from files already on your Mac.

<a name="tier-costly"></a>

### Costly

Shared cache or support data. It can come back, but rebuilding it may take time, bandwidth, or a large download used by more than one project.

<a name="tier-destructive"></a>

### Destructive

May contain backups, settings, user data, or files that are hard to recreate. Review these one at a time before selecting them.