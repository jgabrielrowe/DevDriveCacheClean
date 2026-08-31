# DevDriveCacheClean Trademark and Branding Policy

The DevDriveCacheClean software license governs rights in the software
itself. It does not grant rights to use the project's names, logos,
icons, or other branding.

This policy describes permitted uses of DevDriveCacheClean branding.

## Project Marks

The following names and branding are reserved to the project owner to
the extent protected by applicable trademark and other law:

- DevDriveCacheClean
- The official DevDriveCacheClean application icon
- The official DevDriveCacheClean logo
- Other graphics specifically identified as official DDCC branding

"DDCC" is deliberately **not** on that list. The project uses it
throughout, including as the name of the installed application bundle,
but it is a four-letter abbreviation in general use, and claiming
exclusive rights in it would be neither credible nor enforceable. Anyone
may use "DDCC", subject only to the rule against branding a fork so as
to imply it is official.

## Permitted Uses

You may use the DevDriveCacheClean name when truthfully referring to
the official software or project.

Examples include:

- "This tool is compatible with DevDriveCacheClean."
- "This project is based on DevDriveCacheClean."
- "Forked from the DDCC project."
- Linking to or discussing the official DevDriveCacheClean project.
- Accurately identifying DevDriveCacheClean in reviews, articles,
  documentation, or comparisons.

## Modified Versions and Forks

If you distribute a modified version or fork of DevDriveCacheClean,
you must give that version a name and branding that clearly
distinguishes it from the official DevDriveCacheClean project.

Unless you have received written permission from the project owner,
you may not:

- Present a modified version as an official DevDriveCacheClean release.
- Use "DevDriveCacheClean" as the primary name of a fork.
- Use the official application icon or logo as the icon or logo of a
  modified version.
- Use branding that is likely to cause users to believe that a fork
  is produced, endorsed, or maintained by the official project.

A fork may accurately state that it is "based on DevDriveCacheClean"
or "a fork of DevDriveCacheClean."

## Bundle Identifier

The official application ships with the bundle identifier
`com.jgabrielrowe.devdrivecacheclean`.

This identifier is functional rather than decorative. macOS keys Full
Disk Access and other privacy permissions to the bundle identifier, so
two applications sharing one contend for the same grant on a user's
machine. A fork shipping under the official identifier would therefore
interfere with the official application's permissions, independently of
any question about branding.

A modified version or fork must ship under its own bundle identifier.
This requires no change to the build script: `Scripts/make-app.sh` reads
a `DDCC_BUNDLE_ID` override from `Scripts/signing.local.sh`, which is not
tracked in git, so a fork sets its own identifier there alongside its own
signing identity.

## No Endorsement

Use of the DevDriveCacheClean name to truthfully describe
compatibility, origin, or relationship does not imply endorsement by
the DevDriveCacheClean project or project owner.

## Permission

Uses not covered by this policy require prior written permission from
the project owner. Request it at support@devdrivecacheclean.com.
