#!/usr/bin/env python3
# Print the newest Tribblix x86 milestone release, e.g. "0m40". Empty
# output means "nothing detected" and is not an error; a non-zero exit
# means detection itself is broken (network error, HTTP error, or a page
# that no longer matches the expected shape) and must be reported by the
# caller, never swallowed. A failure must NEVER print a plausible-but-wrong
# version -- the version is only printed after every step below has
# succeeded.
#
# Source of truth: https://www.tribblix.org/download.html
# (iso.tribblix.org/iso/ itself has autoindexing disabled -- a HEAD there
# returns "200 OK" with Content-Length: 0, no directory listing at all --
# so the hand-maintained download page on the main site is the only public
# listing of the current release.)
# Fetched and confirmed by hand (2026-07-26): the page is static HTML; the
# current x86 standard-image release is linked near the top as
#   <p>Milestone m40, standard image</p>
#   <ul>
#   <li><a href="https://iso.tribblix.org/iso/tribblix-0m40.iso">Tribblix
#     0m40</a> ...
# The same page also links tribblix-0m40-minimal.iso (server variant),
# omnitribblix-0m40lx*.iso (LX-zone variant), and
# tribblix-sparc-0m34.iso (a different, independently-versioned SPARC
# port) -- none of those must be picked up. Anchoring on the literal
# "tribblix-<rel>.iso" (no extra "-minimal"/"-sparc"/"omnitribblix-"
# text glued to it) selects only the one link this builder's VM_ISO_LINK
# downloads.
#
# stdlib only (urllib.request, re, sys, os) -- no external dependencies.

import os
import re
import sys
import urllib.request

URL = "https://www.tribblix.org/download.html"
TIMEOUT = 60
USER_AGENT = "anyvm-org-upstream-watcher/1.0"

PATTERN = re.compile(
    r'href="https://iso\.tribblix\.org/iso/tribblix-(0m\d+(?:\.\d+)?)\.iso"')


def resolve_natural_key():
    """Return the engine's own natural_key, or fail loudly.

    watch.yml clones base-builder INTO the builder repo root, so at
    detection time it sits at "base-builder/" (relative to this hook's
    cwd, the builder repo root). A local checkout instead has it as a
    sibling, "../base-builder". Try both, in that order.

    There is deliberately NO local fallback copy. Ordering must be the
    single rule the engine uses -- a per-hook duplicate would have to be
    kept in sync by hand across every builder and would drift silently,
    and a hook that ranks versions differently from watch.py is worse
    than one that refuses to run. Both real contexts (CI and a local
    sibling checkout) always provide base-builder, so an ImportError here
    means the environment is wrong: report it as broken detection rather
    than guessing an order.
    """
    for candidate in ("base-builder", os.path.join("..", "base-builder")):
        if not os.path.isdir(candidate):
            continue
        path = os.path.abspath(candidate)
        if path not in sys.path:
            sys.path.insert(0, path)
        try:
            import gendata
            return gendata.natural_key
        except ImportError:
            continue
    raise ImportError(
        "base-builder/gendata.py not importable from %s; expected it at "
        "./base-builder (CI) or ../base-builder (local checkout)"
        % os.getcwd())


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
        return resp.read().decode("utf-8", "replace")


def main():
    try:
        key = resolve_natural_key()
    except ImportError as e:
        sys.stderr.write("upstream_check: %s\n" % e)
        return 1
    try:
        html = fetch(URL)
    except Exception as e:
        sys.stderr.write("upstream_check: fetch of %s failed: %s\n"
                         % (URL, e))
        return 1
    versions = PATTERN.findall(html)
    if not versions:
        sys.stderr.write("upstream_check: no tribblix-<rel>.iso link found "
                         "in %s; page shape may have changed\n" % URL)
        return 1
    newest = sorted(set(versions), key=key)[-1]
    print(newest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
