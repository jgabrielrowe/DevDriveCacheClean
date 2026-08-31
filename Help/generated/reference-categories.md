# Categories

What each Caches category contains, and what usually recreates it.

<a name="category-nodejs"></a>

### Node.js

node_modules directories inside projects, reinstalled with npm, yarn or pnpm from the project's lockfile. Also node versions kept by nvm that nothing is using: the newest, the one nvm's own alias points at, and any version a running process is using are never offered. A version you do remove comes back with nvm install, so it is tier 2.

<a name="category-python"></a>

### Python

Virtual environments, __pycache__, and the caches left by pytest, mypy, tox and ruff, all of which live beside a project and are recreated from its requirements. The uv download cache in ~/.cache/uv is shared by every project instead, so removing it costs a re-download rather than a rebuild — which is why it is tier 2 and the rest are tier 1. Python versions installed by pyenv are listed on the same terms as node versions: the newest, the one pyenv points at, and any version in use are held back.

<a name="category-rust"></a>

### Rust

target directories next to Cargo.toml. Rebuild them with cargo build.

<a name="category-java-kotlin"></a>

### Java/Kotlin

build, .gradle, and target directories next to Gradle or Maven project files. Rebuild them with the project's build command.

<a name="category-xcode"></a>

### Xcode

DerivedData rebuilds on the next build. Device support and simulator runtimes can be downloaded again. Xcode Archives and simulator Devices may contain crash-symbol files, installed apps, and simulator data, so review those carefully.

<a name="category-go"></a>

### Go

The Go build cache recompiles from local source. The module download cache can be fetched again when a project needs it.

<a name="category-docker"></a>

### Docker

Docker Desktop stores images and named volumes together in its data directory. Removing it can remove volume data as well as images.

<a name="category-homebrew"></a>

### Homebrew

Downloaded Homebrew packages and source archives. Homebrew downloads them again when an install or upgrade needs them.

<a name="category-package-caches"></a>

### Package Caches

Download caches for npm, pnpm, Cargo, Gradle, pip, Maven, NuGet, and similar tools. They can be fetched again, but removing them may slow the next build or install.

<a name="category-ide-editor"></a>

### IDE & Editor

The VS Code and JetBrains caches rebuild on next launch. Workspace storage in Code/User/workspaceStorage is not a cache: it holds each project's editor state — open files, undo history, per-workspace extension data — which comes back empty rather than rebuilt, so it is tier 2. Installed extensions and JetBrains application support hold settings, keymaps and licences, which is why they are tier 3.

<a name="category-macos-dev-caches"></a>

### macOS Dev Caches

Xcode cache data can be recreated from the installed toolchain. Swift Package Manager cache data may need to download again.

<a name="category-terraform"></a>

### Terraform

.terraform directories next to Terraform configuration. Restore them with terraform init.

<a name="category-web-frameworks"></a>

### Web Frameworks

Framework build output such as .next, .nuxt, and .angular. Rebuild it with the project's build or dev command.

<a name="category-build-output"></a>

### Build Output

dist directories next to package.json. Rebuild them with the project's build script.

<a name="category-game-engines"></a>

### Game Engines

Export templates, derived data and store downloads kept by Godot, Unity and Unreal. A version's files are listed only when no editor of that version is installed. The engines themselves are not listed here; remove those from the Uninstall view.

<a name="category-app-caches"></a>

### App Caches

Per-app cache folders under ~/Library/Caches and app container caches. HTTPStorages may include website data such as cookies, so review that category before enabling it.

<a name="category-browser-data"></a>

### Browser Data

Browser caches can be downloaded again as you browse. Local storage, databases, and service workers may hold site data or sessions, so they are treated as destructive.

<a name="category-ios-backups"></a>

### iOS Backups

Local iPhone and iPad backups. They may be the only copy of a device's data; DDCC cannot tell whether the same device is backed up elsewhere.

<a name="category-saved-app-state"></a>

### Saved App State

Saved application state used to reopen windows and documents after an app relaunch. Removing it resets that restore state.

<a name="category-mail-downloads"></a>

### Mail Downloads

Mail downloads and attachments stored locally. Some accounts can download them again; local-only mail may not.

<a name="category-system-caches"></a>

### System Caches

Cache data created by macOS services. User-owned caches can be rebuilt by the system. Root-owned caches are shown for information only.

<a name="category-logs-crashes"></a>

### Logs & Crashes

Diagnostic logs and crash reports. Removing them frees space but also removes history you may want for troubleshooting.

<a name="category-app-deep-clean"></a>

### App Deep Clean

Known cache and support-data locations for specific apps. DDCC only lists paths it recognizes; nearby app data is left alone.