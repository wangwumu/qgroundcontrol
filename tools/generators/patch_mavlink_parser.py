#!/usr/bin/env python3
"""Remove the MAVLink v2 parser's "unknown incompat flag" rejection.

The 32-bit deviceID scheme (docs/10_deviceID与payload加密公共规范.md §1.4/§1.5)
repurposes the frame-header incompat_flags byte (offset 2) as the high byte of the
deviceID. The upstream parser rejects any frame whose incompat_flags has bits other
than MAVLINK_IFLAG_SIGNED (bit 0) set, which would cap the usable deviceID at 24
bits. This script deletes that rejection block so bits 25..31 parse correctly, while
leaving the bit-0 SIGNED determination intact.

It operates on the CPM-generated header in the build tree, so QGC stays pinned to
the upstream mavlink commit. The script is idempotent: if the block is already gone,
the file is left untouched. If the upstream header changes the block in a way this
script cannot match, it fails loudly instead of silently skipping the patch.

Usage: patch_mavlink_parser.py <mavlink_helpers.h>
"""
import re
import sys

# Opening line of the rejection block (unique in mavlink_helpers.h). CRLF-tolerant.
REJECT_IF_RE = re.compile(
    r'^[ \t]*if \(\(rxmsg->incompat_flags & ~MAVLINK_IFLAG_MASK\) != 0\) \{\r?\n',
    re.MULTILINE,
)

# Semantic fingerprint of "incompat_flags is ANDed with a negated mask": any remaining
# occurrence is a rejection that still needs removing. Used to tell "already patched"
# apart from "regex is stale" without coupling to the MAVLINK_IFLAG_MASK symbol.
REJECT_SEMANTIC_RE = re.compile(r'incompat_flags\s*&\s*~')


def strip_rejection_block(text):
    """Remove the rejection block via brace matching. Returns (new_text, removed)."""
    match = REJECT_IF_RE.search(text)
    if match is None:
        return text, 0

    open_brace = match.group(0).rfind('{')
    i = match.start() + open_brace + 1
    depth = 1
    while i < len(text) and depth > 0:
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
        i += 1

    if depth != 0:
        return text, 0  # unbalanced; caller reports the semantic mismatch

    # Consume the closing '}' line's trailing newline (LF or CRLF).
    j = i
    if j < len(text) and text[j] == '\r':
        j += 1
    if j < len(text) and text[j] == '\n':
        j += 1

    return text[:match.start()] + text[j:], 1


def patch(path):
    try:
        with open(path, 'r', encoding='utf-8', newline='') as f:
            original = f.read()
    except OSError as e:
        print(f'error: cannot read {path}: {e}', file=sys.stderr)
        return 2

    patched, removed = strip_rejection_block(original)

    if removed == 0:
        if REJECT_SEMANTIC_RE.search(original):
            print(f'error: incompat-flag rejection still present but not matched — '
                  f'update tools/generators/patch_mavlink_parser.py for the new '
                  f'upstream mavlink_helpers.h, otherwise deviceID bits 25..31 will '
                  f'silently stop parsing ({path})', file=sys.stderr)
            return 2
        return 0  # already patched

    # The removal must have dropped the rejection without touching SIGNED handling.
    if REJECT_SEMANTIC_RE.search(patched):
        print(f'error: incompat-flag rejection still present after patch ({path})',
              file=sys.stderr)
        return 2
    if 'MAVLINK_IFLAG_SIGNED' not in patched:
        print(f'error: patch over-matched; MAVLINK_IFLAG_SIGNED handling removed '
              f'in {path}', file=sys.stderr)
        return 2

    try:
        with open(path, 'w', encoding='utf-8', newline='') as f:
            f.write(patched)
    except OSError as e:
        print(f'error: cannot write {path}: {e}', file=sys.stderr)
        return 2

    print(f'patched {path}')
    return 0


def main():
    if len(sys.argv) != 2:
        print('usage: patch_mavlink_parser.py <mavlink_helpers.h>', file=sys.stderr)
        return 2
    return patch(sys.argv[1])


if __name__ == '__main__':
    sys.exit(main())
