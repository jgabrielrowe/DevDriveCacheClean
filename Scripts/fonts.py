#!/usr/bin/env python3
"""Regenerate the site's shipped font subsets and their manifest.

Two subcommands:

  manifest  hash the fonts already in Site/assets/fonts and record the
            characters they carry, changing no font file
  subset    rebuild Site/assets/fonts from Fonts/originals, keeping only the
            characters the built site uses, then write the manifest

Needs fonttools; `swift run SiteBuilder` does not. Run `subset` after any
copy change that introduces a character the site has not used before — the
build will tell you when that happens.

`manifest` works from a clean checkout. `subset` additionally needs the
unsubsetted faces in Fonts/originals, which are not committed: they are the
upstream IBM Plex Mono, Instrument Sans and Instrument Serif releases, and
the OFL text shipped beside each subset in Site/assets/fonts names them.
"""
import hashlib
import html
import io
import json
import pathlib
import sys

from fontTools.ttLib import TTFont
from fontTools import subset

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHIPPED = ROOT / "Site" / "assets" / "fonts"
ORIGINALS = ROOT / "Fonts" / "originals"
MANIFEST = ROOT / "Site" / "fonts-manifest.json"


def site_codepoints():
    """Every codepoint the built pages can render, references resolved.

    Mirrors Sources/SiteGen/HTMLText.swift. The two must agree; the build
    check is what notices if they drift.
    """
    found = set()
    for page in (ROOT / "docs").rglob("*.html"):
        text = html.unescape(page.read_text(errors="ignore"))
        found |= {ord(c) for c in text if ord(c) >= 0x20}
    return found


def write_manifest():
    # Union, not intersection: CSS assigns each element one explicit
    # font-family (mono/sans/serif) rather than picking a face per
    # character, so a glyph only one face carries (e.g. the currency row,
    # mono-only) is safe as long as that is the only face ever asked to
    # render it. Subsetting only removes glyphs a face already had, so a
    # face's contribution to the union is exactly what it was told to keep.
    faces, coverage = [], set()
    for path in sorted(SHIPPED.glob("*.woff2")):
        data = path.read_bytes()
        faces.append({
            "file": path.name,
            "sha256": hashlib.sha256(data).hexdigest(),
            "byteCount": len(data),
        })
        coverage |= set(TTFont(path).getBestCmap())
    MANIFEST.write_text(json.dumps({
        "codepoints": sorted(coverage),
        "faces": faces,
    }, indent=2) + "\n")
    print(f"manifest: {len(faces)} faces, {len(coverage)} codepoints covered")


# OFL 1.1 condition 3: a Modified Version may not carry the Reserved Font Name,
# and subsetting is modification -- "deleting ... any of the components".
# IBM Plex declares Reserved Font Name "Plex", so the subsets are renamed. The
# Instrument families declare no reserved name and keep theirs.
#
# Applied here rather than to the files afterwards: a rename that a rebuild
# undoes is not a rename.
RESERVED = {"IBM Plex Mono": "DDCC Mono"}


def clear_reserved_names(font):
    """Rewrite the name table so no Reserved Font Name survives subsetting."""
    for record in font["name"].names:
        try:
            value = record.toUnicode()
        except UnicodeDecodeError:
            continue
        for reserved, replacement in RESERVED.items():
            if reserved in value:
                record.string = value.replace(reserved, replacement)
            compact = reserved.replace(" ", "")
            if compact in value:
                record.string = record.toUnicode().replace(
                    compact, replacement.replace(" ", ""))


def do_subset():
    # Every printable ASCII character, plus everything the site uses today.
    # The ASCII floor is headroom: ordinary copy edits then never trip the
    # build, and only a genuinely new symbol does.
    keep = {c for c in range(0x20, 0x7F)} | site_codepoints()
    total_before = total_after = 0
    for source in sorted(ORIGINALS.glob("*.woff2")):
        target = SHIPPED / source.name
        before = target.stat().st_size if target.exists() else 0
        font = TTFont(source)
        options = subset.Options()
        options.flavor = "woff2"
        options.layout_features = ["*"]
        options.notdef_outline = True
        subsetter = subset.Subsetter(options=options)
        subsetter.populate(unicodes=sorted(keep))
        subsetter.subset(font)
        clear_reserved_names(font)
        buffer = io.BytesIO()
        font.flavor = "woff2"
        font.save(buffer)
        target.write_bytes(buffer.getvalue())
        after = target.stat().st_size
        total_before += before
        total_after += after
        print(f"  {source.name:34} {before/1024:6.1f} KB -> {after/1024:6.1f} KB")
    print(f"  {'TOTAL':34} {total_before/1024:6.1f} KB -> {total_after/1024:6.1f} KB")
    write_manifest()


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "manifest":
        write_manifest()
    elif command == "subset":
        do_subset()
    else:
        print(__doc__)
        sys.exit(2)
