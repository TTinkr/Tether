#!/usr/bin/env python3
import pathlib
import re
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from swiftlex import lex  # noqa: E402

REPO = HERE.parent
MAX_SPREAD = 18   # never push a sign further right than this many columns
MAX_WIDTH = 120   # never make a line longer than this

# Reading a file as lines of (character, kind)


def kinds_by_line(text):
    """For every line: the kind ('code', 'comment', 'string') of each of its characters."""
    kinds = []
    for kind, chunk in lex(text):
        kinds.extend([kind] * len(chunk))
    out, start = [], 0
    for line in text.split("\n"):
        out.append(kinds[start:start + len(line)])
        start += len(line) + 1
    return out


def depth_zero_positions(line, kinds, needle):
    """Columns where `needle` appears in plain code, outside every bracket on this line."""
    found, depth = [], 0
    for col, char in enumerate(line):
        if kinds[col] != "code":
            continue
        if char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif depth == 0 and line.startswith(needle, col) and all(k == "code" for k in kinds[col:col + len(needle)]):
            found.append(col)
    return found


def balanced(line, kinds):
    depth = 0
    for col, char in enumerate(line):
        if kinds[col] == "code":
            depth += (char in "([{") - (char in ")]}")
            if depth < 0:
                return False
    return depth == 0


# The three anchors a line can offer

ASSIGN_START = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|static|final|lazy|weak|nonisolated|override|private\(set\)|fileprivate\(set\))\s+)*(?:let |var |case |[A-Za-z_][\w.]*(?:\[[^\]]*\])? = )")


def assign_anchor(line, kinds):
    """Column of the ` = ` to align, or None. Only whole one-line declarations and assignments."""
    if not line.strip() or kinds[0:1] not in (["code"], []) or not ASSIGN_START.match(line):
        return None
    if not balanced(line, kinds) or line.rstrip().endswith(("{", "(", "[", ",")):
        return None
    spots = depth_zero_positions(line, kinds, " = ")
    if not spots:
        return None
    # `case .top: point = ...` is a switch arm, not an enum raw value: its `=` belongs to the body.
    if line.lstrip().startswith("case ") and any(c < spots[0] for c in depth_zero_positions(line, kinds, ": ")):
        return None
    return spots[0] + 1
#
# :)
#
#
def case_anchor(line, kinds):
    """Column where a one-line `case ...:` arm's body starts, or None."""
    stripped = line.lstrip()
    if kinds[0:1] != ["code"] or not balanced(line, kinds):
        return None
    if not (stripped.startswith("case ") or stripped.startswith("default:")):
        return None
    spots = depth_zero_positions(line, kinds, ": ")
    if not spots:
        return None
    # The anchor is where the body really starts, so an already aligned arm is left alone.
    body = spots[0] + 1
    while body < len(line) and line[body] == " ":
        body += 1
    return body if body < len(line) and kinds[body] == "code" else None


def comment_anchor(line, kinds):
    """Column where a trailing `//` comment starts on a line that also has code, or None."""
    for col in range(1, len(line) - 1):
        if kinds[col] != "comment":
            continue
        # The first comment character on the line decides: a `//` after code and a space, or nothing.
        if line.startswith("//", col) and line[col - 1] == " " and line[:col].strip() and kinds[0] == "code":
            return col
        return None
    return None


# Aligning runs


def indent_of(line):
    return len(line) - len(line.lstrip())


def align_runs(lines, kinds, anchor_of):
    """Pad each run of neighbouring anchored lines so their anchors share a column."""
    changed, index = 0, 0
    while index < len(lines):
        anchor = anchor_of(lines[index], kinds[index])
        if anchor is None:
            index += 1
            continue
        run, indent = [(index, anchor)], indent_of(lines[index])
        probe = index + 1
        while probe < len(lines) and indent_of(lines[probe]) == indent:
            next_anchor = anchor_of(lines[probe], kinds[probe])
            if next_anchor is None:
                break
            run.append((probe, next_anchor))
            probe += 1
        index = probe
        if len(run) < 2:
            continue
        target = max(a for _, a in run)
        spread = target - min(a for _, a in run)
        widest = max(len(lines[i]) + target - a for i, a in run)
        if spread == 0 or spread > MAX_SPREAD or widest > MAX_WIDTH:
            continue
        for i, a in run:
            pad = target - a
            if pad:
                lines[i] = lines[i][:a] + " " * pad + lines[i][a:]
                kinds[i] = kinds[i][:a] + ["code"] * pad + kinds[i][a:]
                changed += 1
    return changed


def squeeze(text):
    """Every character that is not a space or tab outside strings; what alignment must not change."""
    return "".join(chunk if kind == "string" else re.sub(r"[ \t]+", "", chunk) for kind, chunk in lex(text))
#
# :)
#
#
def align_text(text):
    lines = text.split("\n")
    kinds = kinds_by_line(text)
    changed = align_runs(lines, kinds, assign_anchor)
    changed += align_runs(lines, kinds, case_anchor)
    changed += align_runs(lines, kinds, comment_anchor)
    return "\n".join(lines), changed


# main


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry, everything = "--dry-run" in sys.argv, "--all" in sys.argv
    if args:
        paths = [pathlib.Path(a).resolve() for a in args]
    else:
        paths = sorted(list((REPO / "Sources").rglob("*.swift")) + list((REPO / "Tests").rglob("*.swift")))
    dirty = set()
    if not everything and not args:
        status = subprocess.run(["git", "status", "--short"], cwd=REPO, capture_output=True, text=True).stdout
        dirty = {(REPO / line[3:].strip()).resolve() for line in status.split("\n") if line.strip()}
    files = lines_moved = busy = refused = 0
    for path in paths:
        if path in dirty:
            busy += 1
            continue
        text = path.read_text()
        new, changed = align_text(text)
        if not changed:
            continue
        if squeeze(new) != squeeze(text):
            refused += 1
            print(f"  refused (would change more than spacing): {path.relative_to(REPO)}")
            continue
        if not dry:
            path.write_text(new)
        files += 1
        lines_moved += changed
    print(f"{'would align' if dry else 'aligned'} {lines_moved} lines in {files} files; "
          f"skipped {busy} with uncommitted changes; refused {refused}")


if __name__ == "__main__":
    raise SystemExit(main())
