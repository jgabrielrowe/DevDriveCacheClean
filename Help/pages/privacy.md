# Privacy

DDCC runs locally on your Mac.

It has no analytics, telemetry, account, update check, crash reporter, or cloud
sync. It does not send scan results anywhere.

Scanning uses file metadata such as paths, sizes, modification dates, and
directory structure. DDCC does not need to read the contents of your files to
classify cache results.

QuickLook previews are shown by macOS from the selected local file. DDCC does
not upload the file to preview it.

The Full Disk Access check reads one byte from a known protected location to
see whether macOS granted access.

DDCC launches one subprocess in one situation only: removing an app that
belongs to the whole Mac uses `/usr/bin/osascript` to ask Finder to move it, so
macOS can ask you to authenticate. Nothing about your files leaves the Mac when
it does.

The source is available for review, including the absence of network code.
