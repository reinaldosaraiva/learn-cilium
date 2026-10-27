"""Behavior tests for the repository-local Markdown link checker."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
CHECKER = REPO / "poc-k8s-fabric/tools/check_relative_links.py"


class RelativeLinkCheckerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.tools = self.root / "poc-k8s-fabric/tools"
        self.tools.mkdir(parents=True)
        (self.tools / "check_relative_links.py").write_bytes(CHECKER.read_bytes())
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def write(self, relative: str, content: str = "") -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")
        return path

    def add(self, *relative_paths: str) -> None:
        subprocess.run(
            ["git", "-C", str(self.root), "add", "--", *relative_paths],
            check=True,
        )

    def run_checker(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                "-I",
                str(self.tools / "check_relative_links.py"),
            ],
            cwd=self.root,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_nested_image_directory_titles_queries_and_encoded_names(self) -> None:
        self.write("docs/index.md", """[page](nested/page.md "title")
![image](images/cover.png?size=small#preview)
[section](nested/)
[encoded](nested/space%20name.md#heading)
[external](https://example.test/page)
[fragment](#intro)
""")
        self.write("docs/nested/page.md")
        self.write("docs/nested/space name.md")
        self.write("docs/nested/child.md")
        self.write("docs/images/cover.png", "image")
        self.add("docs/index.md", "docs/nested/page.md", "docs/nested/space name.md",
                 "docs/nested/child.md", "docs/images/cover.png")

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_untracked_nonignored_markdown_is_a_public_source(self) -> None:
        self.write("docs/index.md", "[missing](absent.md)\n")
        self.add("docs/index.md")
        source = self.write("docs/untracked.md", "[missing](absent.md)\n")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/untracked.md:1: absent.md", result.stdout)
        self.assertTrue(source.exists())

    def test_missing_target_reports_source_line_and_destination(self) -> None:
        self.write("docs/index.md", "Text\n[missing](gone.md)\n")
        self.add("docs/index.md")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/index.md:2: gone.md", result.stdout)

    def test_existing_ignored_target_is_not_public(self) -> None:
        self.write(".gitignore", "docs/private.md\n")
        self.write("docs/index.md", "[ignored](private.md)\n")
        self.write("docs/private.md", "exists but is ignored")
        self.add(".gitignore", "docs/index.md")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/index.md:1: private.md", result.stdout)

    def test_nonignored_evidence_markdown_is_checked(self) -> None:
        self.write("docs/evidence/index.md", "[missing](absent.md)\n")
        self.add("docs/evidence/index.md")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/evidence/index.md:1: absent.md", result.stdout)

    def test_markdown_source_symlink_is_rejected_without_reading_target(self) -> None:
        marker = "SYNTHETIC_PRIVATE_CONTENT_DO_NOT_PRINT"
        self.write(".gitignore", "docs/evidence/private.md\n")
        private = self.write("docs/evidence/private.md", marker)
        public = self.root / "public.md"
        public.symlink_to("docs/evidence/private.md")
        self.add(".gitignore", "public.md")

        result = self.run_checker()

        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1)
        self.assertIn("public.md:1: [fonte Markdown symlink recusada]", result.stdout)
        self.assertNotIn(marker, output)
        self.assertTrue(private.exists())

    def test_nul_percent_encoded_target_has_a_line_diagnostic(self) -> None:
        self.write("docs/index.md", "Text\n[invalid](%00.md)\n")
        self.add("docs/index.md")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/index.md:2: %00.md", result.stdout)
        self.assertNotIn("Traceback", result.stdout + result.stderr)

    def test_double_slash_percent_encoded_target_has_a_line_diagnostic(self) -> None:
        self.write("docs/index.md", "Text\n[invalid](%2F%2Foutside.md)\n")
        self.add("docs/index.md")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/index.md:2: %2F%2Foutside.md", result.stdout)
        self.assertNotIn("Traceback", result.stdout + result.stderr)

    def test_links_inside_fenced_and_inline_code_are_ignored(self) -> None:
        self.write("docs/index.md", """`[inline](missing.md)`

```markdown
[fenced](missing.md)
```

~~~
[tilde fenced](missing.md)
~~~
""")
        self.add("docs/index.md")

        result = self.run_checker()

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_target_cannot_escape_repository_root(self) -> None:
        self.write("docs/index.md", "[escape](../../outside.md)\n")
        self.add("docs/index.md")

        result = self.run_checker()

        self.assertEqual(result.returncode, 1)
        self.assertIn("docs/index.md:1: ../../outside.md", result.stdout)


if __name__ == "__main__":
    unittest.main()
