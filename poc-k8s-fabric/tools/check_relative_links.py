#!/usr/bin/env python3
"""Check local Markdown links from Git-listed files in this worktree.

Markdown source symlinks are rejected before their contents are read.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit


_LINK = re.compile(
    r"!?\[[^\]\n]*\]\(\s*(?:<([^>\n]*)>|((?:\\.|[^()\s])+))"
    r"(?:\s+(?:\"[^\"]*\"|'[^']*'|[^)]*))?\s*\)"
)
_FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_INLINE_CODE = re.compile(r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)", re.DOTALL)


def _git_paths(root: Path) -> set[PurePosixPath]:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(root),
            "ls-files",
            "--cached",
            "--others",
            "--exclude-standard",
            "-z",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )
    return {
        PurePosixPath(raw.decode("utf-8", errors="surrogateescape"))
        for raw in result.stdout.split(b"\0")
        if raw
    }


def _mask_code(text: str) -> str:
    masked = list(text)
    in_fence: tuple[str, int] | None = None
    offset = 0
    for line in text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        fence = _FENCE.match(content)
        if in_fence is None and fence:
            in_fence = (fence.group(1)[0], len(fence.group(1)))
        elif in_fence is not None and fence:
            run = fence.group(1)
            if run[0] == in_fence[0] and len(run) >= in_fence[1]:
                in_fence = None
        if in_fence is not None or fence:
            for index in range(offset, offset + len(line)):
                if masked[index] not in "\r\n":
                    masked[index] = " "
        offset += len(line)

    fenced_mask = "".join(masked)
    for match in _INLINE_CODE.finditer(fenced_mask):
        for index in range(match.start(), match.end()):
            if masked[index] not in "\r\n":
                masked[index] = " "
    return "".join(masked)


def _public_paths(
    root: Path,
) -> tuple[set[PurePosixPath], set[PurePosixPath], set[PurePosixPath]]:
    paths = _git_paths(root)
    files: set[PurePosixPath] = set()
    markdown: set[PurePosixPath] = set()
    for path in paths:
        candidate = root / Path(*path.parts)
        if candidate.is_file() and not candidate.is_symlink():
            files.add(path)
        if path.suffix.lower() == ".md" and (candidate.is_file() or candidate.is_symlink()):
            markdown.add(path)

    directories: set[PurePosixPath] = {PurePosixPath(".")}
    for path in paths:
        candidate = root / Path(*path.parts)
        if not (candidate.is_file() or candidate.is_symlink()):
            continue
        directories.update(path.parents)
    return markdown, files | directories, files


def _destination_path(source: PurePosixPath, destination: str) -> PurePosixPath | None:
    if not destination or destination.startswith("#"):
        return None
    try:
        parsed = urlsplit(destination)
    except ValueError:
        return PurePosixPath("..", "__invalid_url__")
    if parsed.scheme or parsed.netloc:
        return None
    raw_path = unquote(parsed.path)
    if not raw_path:
        return None
    target = PurePosixPath(raw_path)
    if target.is_absolute():
        return target.relative_to("/")
    return source.parent / target


def _validate_target(
    root: Path,
    target: PurePosixPath,
    public_targets: set[PurePosixPath],
) -> bool:
    try:
        candidate = (root / Path(*target.parts)).resolve(strict=False)
        resolved_root = root.resolve()
        candidate.relative_to(resolved_root)
    except (OSError, RuntimeError, ValueError):
        return False
    normalized = PurePosixPath(candidate.relative_to(resolved_root).as_posix())
    if normalized == PurePosixPath("."):
        return normalized in public_targets
    return normalized in public_targets and candidate.exists()


def _source_error(
    root: Path,
    source: PurePosixPath,
    public_files: set[PurePosixPath],
) -> str | None:
    file_path = root / Path(*source.parts)
    if file_path.is_symlink():
        return f"{source}:1: [fonte Markdown symlink recusada]"
    try:
        resolved_root = root.resolve()
        resolved_source = file_path.resolve(strict=True)
        relative_source = resolved_source.relative_to(resolved_root)
    except (OSError, RuntimeError, ValueError):
        return f"{source}:1: [fonte Markdown fora da raiz ou não resolvida]"
    public_path = PurePosixPath(relative_source.as_posix())
    if public_path not in public_files or not resolved_source.is_file():
        return f"{source}:1: [fonte Markdown fora do conjunto público]"
    return None


def check(root: Path) -> tuple[list[str], int, int]:
    markdown, public_targets, public_files = _public_paths(root)
    failures: list[str] = []
    checked_links = 0
    for source in sorted(markdown, key=lambda path: path.as_posix()):
        source_error = _source_error(root, source, public_files)
        if source_error:
            failures.append(source_error)
            continue
        file_path = root / Path(*source.parts)
        text = file_path.read_text(encoding="utf-8", errors="replace")
        visible = _mask_code(text)
        for match in _LINK.finditer(visible):
            destination = match.group(1) or match.group(2) or ""
            try:
                target = _destination_path(source, destination)
            except (OSError, RuntimeError, ValueError):
                checked_links += 1
                line = text.count("\n", 0, match.start()) + 1
                failures.append(f"{source}:{line}: {destination}")
                continue
            if target is None:
                continue
            checked_links += 1
            try:
                valid_target = _validate_target(root, target, public_targets)
            except (OSError, RuntimeError, ValueError):
                valid_target = False
            if not valid_target:
                line = text.count("\n", 0, match.start()) + 1
                failures.append(f"{source}:{line}: {destination}")
    return failures, len(markdown), checked_links


def main() -> int:
    root = Path(__file__).resolve().parents[2]
    try:
        failures, source_count, link_count = check(root)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"erro ao verificar links: {error}", file=sys.stderr)
        return 2
    if failures:
        for failure in failures:
            print(failure)
        print(f"{link_count} links relativos verificados em {source_count} fontes Markdown.")
        return 1
    print(
        f"Links relativos Markdown válidos: {link_count} destinos em "
        f"{source_count} fontes Markdown."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
