# Contributing to DevDriveCacheClean

Thank you for your interest in contributing to DevDriveCacheClean.

Bug reports, feature requests, testing, documentation improvements,
and code contributions are welcome.

## Contributor License Agreement

Before a code, documentation, artwork, or other copyrightable
contribution can be merged into DevDriveCacheClean, the contributor
must agree to the DevDriveCacheClean Contributor License Agreement
found in [CLA.md](CLA.md).

The CLA does not transfer ownership of your contribution to the
DevDriveCacheClean project.

You retain copyright in your contribution.

The CLA instead grants the project owner the rights necessary to:

- Include your contribution in DDCC.
- Modify and distribute it.
- Continue distributing DDCC under SUL-1.0.
- Change the project's license in the future.
- Offer DDCC under a separate commercial license.
- Transfer or sublicense the relevant project rights to a successor
  project owner.

This avoids requiring every past contributor to approve a future
licensing change.

## Agreeing to the CLA

Before your first contribution is merged, please state the following
in the pull request:

> I have read and agree to the DevDriveCacheClean Contributor License
> Agreement v1.0.

The project maintainer may request additional confirmation or an
entity authorization for contributions made on behalf of an employer
or other organization.

## Your Contributions

By submitting a contribution, you represent that you have the legal
right to submit it.

Do not submit:

- Code copied from another project unless its license permits the
  contribution and you clearly identify its source and license.
- Proprietary source code belonging to an employer or another party.
- Assets, code, or other material for which you cannot grant the
  rights described in the CLA.

If your employer may own intellectual-property rights in work you
create, make sure you have any authorization required before
contributing.

### Third-party code

DDCC currently has **no third-party dependencies**: it declares no
external packages, and every import is either an Apple system framework
or a DDCC module. That is a deliberate property, not an accident of
scale — it keeps the supply chain empty for a tool that asks for Full
Disk Access and deletes files.

Contributions that would add a dependency, or that vendor code from
another project, are therefore a larger decision than their diff size
suggests, and should be raised in an issue before the work is done.
Third-party code carries its own license terms, which persist through
any future relicensing of DDCC.

## Pull Requests

Please keep pull requests focused where practical.

For behavioral changes:

1. Explain the problem being solved.
2. Describe the proposed behavior.
3. Include or update tests where appropriate.
4. Note any filesystem locations, APIs, or macOS behavior affected by
   the change.
5. Call out operations that may delete or modify user data.

Because DDCC performs filesystem cleanup and application removal,
changes involving deletion behavior should be conservative,
reviewable, and testable.

## Licensing of Accepted Contributions

Accepted contributions become part of the DevDriveCacheClean project
and may be distributed under SUL-1.0 and as otherwise permitted by
the Contributor License Agreement.

Submitting a contribution does not grant the contributor rights to
the DevDriveCacheClean names, logos, icon, or other official project
branding.

If you distribute a fork rather than contributing upstream, note that
it must ship under its own name, branding, and **bundle identifier** —
macOS keys Full Disk Access to the identifier, so a fork sharing the
official one interferes with the official application's permissions.
See [TRADEMARKS.md](TRADEMARKS.md).
