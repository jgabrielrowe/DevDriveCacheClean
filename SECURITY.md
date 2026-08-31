# Security policy

DDCC asks for Full Disk Access and deletes files. If you find a way to make it
do something it should not, please report it privately rather than in public.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting on this repository: **Security →
Report a vulnerability**. That channel is private between you and the
maintainer.

If you would rather not use GitHub, email support@devdrivecacheclean.com
instead, and say in the subject line that it is a security report so it is not
read as an ordinary support message.

Please do not open a public issue for a security problem. The issue tracker is
the right place for bugs and questions, and the wrong place for anything that
would tell other people how to exploit a machine before there is a fix.

## In scope

- The DDCC application, in any released version.
- The website at devdrivecacheclean.com.

Out of scope: the analytics server, and the third-party services the site links
to.

## What the app does, in security terms

- It runs locally and makes no network connections of any kind.
- Full Disk Access is requested so it can read sizes and directory structure.
  It reads file metadata, not file contents.
- Removals go to the Trash by default; permanent deletion is a separate opt-in.
  Only tier 3, the destructive one, goes further: a selection containing one
  requires typing a word before either will run.
- Paths are attributed to an application by declaration — a container
  identifier, a Homebrew zap stanza, a package receipt — never by matching a
  name.
- One subprocess is launched, in one situation only: `/usr/bin/osascript`, to
  ask Finder to move an application that belongs to the whole Mac, so macOS can
  prompt for authentication. DDCC keeps no elevated rights.

## Good-faith research

If you are investigating in good faith — testing against your own machine, not
accessing anyone else's data, not destroying anything, and giving a reasonable
period to fix before publishing — no action will be pursued against you, and
you will be credited in the release notes if you would like that.

## What to expect

This is a one-person project. There is no team on call and no guaranteed
response window. Reports are read and acknowledged as soon as they are seen,
and anything genuinely exploitable is treated as the next thing to fix.
