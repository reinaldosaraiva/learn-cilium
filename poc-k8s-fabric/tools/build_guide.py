#!/usr/bin/env python3
"""Build the student guide PDF from a Markdown source.

The generator depends only on ReportLab, so documentation builds do not need
the laboratory binaries or a live cluster.
"""

from __future__ import annotations

import argparse
import html
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    Flowable,
    Image,
    KeepTogether,
    PageBreak,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)
from reportlab.lib.utils import ImageReader
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase import pdfmetrics


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / "poc-k8s-fabric" / "docs" / "lab-guide-student.md"
DEFAULT_OUTPUT = ROOT / "output" / "pdf" / "cilium-lab-student-guide.pdf"
PAGE_WIDTH, PAGE_HEIGHT = A4
LEFT_MARGIN = 18 * mm
RIGHT_MARGIN = 16 * mm
TOP_MARGIN = 18 * mm
BOTTOM_MARGIN = 17 * mm
CONTENT_WIDTH = PAGE_WIDTH - LEFT_MARGIN - RIGHT_MARGIN
MAX_CODE_HEIGHT = PAGE_HEIGHT - TOP_MARGIN - BOTTOM_MARGIN - 12
MIN_CODE_FONT_SIZE = 6.2


@dataclass(frozen=True, slots=True)
class Block:
    kind: str
    value: object


@dataclass(frozen=True, slots=True)
class Heading:
    level: int
    text: str


def _register_font() -> tuple[str, str]:
    """Use a Unicode-capable font when the host provides one."""

    candidates = (
        (
            "/System/Library/Fonts/Supplemental/Arial.ttf",
            "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        ),
        (
            "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
            "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
        ),
        (
            "/usr/share/fonts/truetype/liberation2/LiberationSans-Regular.ttf",
            "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf",
        ),
    )
    for regular_path, bold_path in candidates:
        if Path(regular_path).is_file() and Path(bold_path).is_file():
            pdfmetrics.registerFont(TTFont("GuideSans", regular_path))
            pdfmetrics.registerFont(TTFont("GuideSans-Bold", bold_path))
            return "GuideSans", "GuideSans-Bold"
    return "Helvetica", "Helvetica-Bold"


def _inline(text: str, regular_font: str, code_font: str = "Courier") -> str:
    """Convert the small Markdown inline subset into escaped ReportLab XML."""

    text = html.escape(text, quote=False)
    code_fragments: list[str] = []

    def code(match: re.Match[str]) -> str:
        marker = f"\x00CODE{len(code_fragments)}\x00"
        code_fragments.append(
            f'<font name="{code_font}" color="#144B63">{match.group(1)}</font>'
        )
        return marker

    text = re.sub(r"`([^`]+)`", code, text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"\*([^*]+)\*", r"<i>\1</i>", text)
    def link(match: re.Match[str]) -> str:
        label, target = match.groups()
        target = html.unescape(target)
        if target.startswith("#"):
            return label
        if not re.match(r"^https?://", target):
            return label
        return f'<link href="{html.escape(target, quote=True)}" color="#144B63"><u>{label}</u></link>'

    text = re.sub(r"\[([^]]+)\]\(([^)]*)\)", link, text)
    for index, fragment in enumerate(code_fragments):
        text = text.replace(f"\x00CODE{index}\x00", fragment)
    return text


def parse_markdown(path: Path) -> tuple[Block, ...]:
    """Parse headings, prose, lists, tables, fences, boxes and images."""

    lines = path.read_text(encoding="utf-8").splitlines()
    blocks: list[Block] = []
    paragraph: list[str] = []
    index = 0

    def flush_paragraph() -> None:
        if paragraph:
            blocks.append(Block("paragraph", " ".join(line.strip() for line in paragraph)))
            paragraph.clear()

    while index < len(lines):
        line = lines[index]
        if line.startswith("~~~") or line.startswith("```"):
            flush_paragraph()
            fence = line[:3]
            code_lines: list[str] = []
            index += 1
            while index < len(lines) and not lines[index].startswith(fence):
                code_lines.append(lines[index])
                index += 1
            if index < len(lines):
                index += 1
            blocks.append(Block("code", tuple(code_lines)))
            continue
        if line.startswith("#"):
            flush_paragraph()
            match = re.match(r"^(#{1,6})\s+(.+?)\s*#*$", line)
            if match:
                if len(match.group(1)) == 2 and match.group(2).strip() == "Sumário":
                    index += 1
                    while index < len(lines) and (
                        not lines[index].strip()
                        or re.match(r"^\d+\.\s+", lines[index])
                    ):
                        index += 1
                    continue
                blocks.append(Block("heading", Heading(len(match.group(1)), match.group(2))))
                index += 1
                continue
        if line.startswith("!["):
            flush_paragraph()
            match = re.match(r"!\[([^\]]*)\]\(([^)]+)\)", line.strip())
            if match:
                blocks.append(Block("image", match.group(2).strip()))
            index += 1
            continue
        if line.startswith(">"):
            flush_paragraph()
            quote_lines: list[str] = []
            while index < len(lines) and lines[index].startswith(">"):
                quote_lines.append(lines[index][1:].strip())
                index += 1
            blocks.append(Block("box", tuple(quote_lines)))
            continue
        if line.startswith("|"):
            flush_paragraph()
            table_lines: list[str] = []
            while index < len(lines) and lines[index].startswith("|"):
                table_lines.append(lines[index])
                index += 1
            blocks.append(Block("table", tuple(table_lines)))
            continue
        if re.match(r"^\s*[-*] \S", line):
            flush_paragraph()
            list_lines: list[str] = []
            while index < len(lines):
                current = lines[index]
                if re.match(r"^\s*[-*] \S", current):
                    list_lines.append(re.sub(r"^\s*[-*]\s+", "", current))
                    index += 1
                    continue
                if list_lines and current[:1].isspace() and current.strip():
                    list_lines[-1] += " " + current.strip()
                    index += 1
                    continue
                break
            blocks.append(Block("list", tuple(list_lines)))
            continue
        if re.match(r"^\s*\d+\.\s+\S", line):
            flush_paragraph()
            list_lines = []
            while index < len(lines):
                current = lines[index]
                if re.match(r"^\s*\d+\.\s+\S", current):
                    list_lines.append(re.sub(r"^\s*\d+\.\s+", "", current))
                    index += 1
                    continue
                if list_lines and current[:1].isspace() and current.strip():
                    list_lines[-1] += " " + current.strip()
                    index += 1
                    continue
                break
            blocks.append(Block("numbered-list", tuple(list_lines)))
            continue
        if not line.strip():
            flush_paragraph()
            index += 1
            continue
        if re.match(r"^\s*---+\s*$", line):
            flush_paragraph()
            blocks.append(Block("rule", None))
            index += 1
            continue
        paragraph.append(line)
        index += 1
    flush_paragraph()
    return tuple(blocks)


class CodeBlock(Flowable):
    """A split-friendly shaded code box with wrapped long command lines."""

    def __init__(
        self, lines: Sequence[str], font_name: str = "Courier", *,
        continued: bool = False, continues: bool = False,
    ) -> None:
        super().__init__()
        self.lines = tuple(lines)
        self.continued = continued
        self.continues = continues
        self.font_name = font_name
        self.font_size = 8.0
        self.leading = 10.0
        self.padding = 7
        self.width = 0.0
        self._font_sizes: tuple[float, ...] = ()

    def wrap(self, available_width: float, available_height: float) -> tuple[float, float]:
        self.width = available_width
        self._font_sizes = tuple(
            self._font_size_for_line(line, available_width - 2 * self.padding)
            for line in self.lines
        )
        self.height = self._required_height()
        return available_width, self.height

    def _font_size_for_line(self, line: str, available_width: float) -> float:
        if not line:
            return self.font_size
        natural_width = pdfmetrics.stringWidth(line, self.font_name, self.font_size)
        if natural_width <= available_width:
            return self.font_size
        size = self.font_size * available_width / natural_width
        if size < MIN_CODE_FONT_SIZE:
            raise ValueError(
                "Code line is too wide for the PDF code box; "
                f"wrap it at a shell-safe boundary: {line[:80]!r}"
            )
        return size

    def _required_height(self) -> float:
        cues = int(self.continued) + int(self.continues)
        return self.padding * 2 + (len(self.lines) + cues) * self.leading

    def split(self, available_width: float, available_height: float) -> list[Flowable]:
        required_height = self._required_height()
        # A complete box that fits on a fresh page should not split mid-command.
        if required_height <= MAX_CODE_HEIGHT and available_height < required_height:
            return []
        cue_lines = int(self.continued) + 1
        usable = int((available_height - self.padding * 2) // self.leading) - cue_lines
        if usable < 1:
            return []
        if len(self.lines) <= usable:
            return [self]
        return [
            CodeBlock(self.lines[:usable], self.font_name,
                      continued=self.continued, continues=True),
            CodeBlock(self.lines[usable:], self.font_name,
                      continued=True, continues=self.continues),
        ]

    def draw(self) -> None:
        self.canv.setFillColor(colors.HexColor("#F1F6F8"))
        self.canv.setStrokeColor(colors.HexColor("#B8CBD2"))
        self.canv.roundRect(0, 0, self.width, self.height, 4, fill=1, stroke=1)
        self.canv.setFillColor(colors.HexColor("#41606A"))
        self.canv.setFont("Helvetica-Oblique", 7)
        if self.continued:
            self.canv.drawString(self.padding, self.height - self.padding - 7,
                                 "# Continuação do bloco da página anterior")
        if self.continues:
            self.canv.drawString(self.padding, self.padding,
                                 "# O bloco continua na próxima página")
        self.canv.setFillColor(colors.HexColor("#18333D"))
        baseline = self.height - self.padding - self.font_size
        if self.continued:
            baseline -= self.leading
        font_sizes = self._font_sizes or (self.font_size,) * len(self.lines)
        for index, line in enumerate(self.lines):
            self.canv.setFont(self.font_name, font_sizes[index])
            self.canv.drawString(self.padding, baseline, line)
            baseline -= self.leading


class GuideDocTemplate(SimpleDocTemplate):
    """Collect heading pages during each pass for a stable table of contents."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.heading_pages: list[tuple[int, str, int]] = []

    def afterFlowable(self, flowable: Flowable) -> None:
        heading = getattr(flowable, "_guide_heading", None)
        if heading is not None:
            self.heading_pages.append((heading.level, heading.text, self.page))


def _styles(regular_font: str, bold_font: str) -> dict[str, ParagraphStyle]:
    base = getSampleStyleSheet()
    return {
        "body": ParagraphStyle(
            "GuideBody",
            parent=base["BodyText"],
            fontName=regular_font,
            fontSize=8.9,
            leading=12.2,
            textColor=colors.HexColor("#23343A"),
            spaceAfter=6,
            alignment=TA_LEFT,
        ),
        "h2": ParagraphStyle(
            "GuideH2",
            parent=base["Heading2"],
            fontName=bold_font,
            fontSize=16,
            leading=20,
            textColor=colors.HexColor("#0F5268"),
            spaceBefore=13,
            spaceAfter=8,
            keepWithNext=True,
        ),
        "h3": ParagraphStyle(
            "GuideH3",
            parent=base["Heading3"],
            fontName=bold_font,
            fontSize=11.5,
            leading=14,
            textColor=colors.HexColor("#184A5A"),
            spaceBefore=9,
            spaceAfter=5,
            keepWithNext=True,
        ),
        "h4": ParagraphStyle(
            "GuideH4",
            parent=base["Heading4"],
            fontName=bold_font,
            fontSize=9.5,
            leading=12,
            textColor=colors.HexColor("#266176"),
            spaceBefore=7,
            spaceAfter=4,
            keepWithNext=True,
        ),
        "bullet": ParagraphStyle(
            "GuideBullet",
            parent=base["BodyText"],
            fontName=regular_font,
            fontSize=8.6,
            leading=11.5,
            leftIndent=13,
            firstLineIndent=-8,
            bulletIndent=2,
            spaceAfter=3,
        ),
    "table": ParagraphStyle(
            "GuideTable",
            parent=base["BodyText"],
            fontName=regular_font,
            fontSize=8.0,
            leading=9.5,
            wordWrap="CJK",
        ),
    "table-head": ParagraphStyle(
            "GuideTableHead",
            parent=base["BodyText"],
            fontName=bold_font,
            fontSize=8.0,
            leading=9.5,
            textColor=colors.white,
            wordWrap="CJK",
        ),
        "toc": ParagraphStyle(
            "GuideToc",
            parent=base["BodyText"],
            fontName=regular_font,
            fontSize=8.7,
            leading=13,
            textColor=colors.HexColor("#263C44"),
        ),
        "toc-sub": ParagraphStyle(
            "GuideTocSub",
            parent=base["BodyText"],
            fontName=regular_font,
            fontSize=8,
            leading=11,
            leftIndent=12,
            textColor=colors.HexColor("#49626B"),
        ),
        "box": ParagraphStyle(
            "GuideBox",
            parent=base["BodyText"],
            fontName=regular_font,
            fontSize=8.3,
            leading=11.3,
            textColor=colors.HexColor("#263B42"),
        ),
    }


def _wrapped_code(lines: Sequence[str]) -> tuple[str, ...]:
    """Keep Markdown command lines intact for copyable PDF output.

    CodeBlock scales an unusually long line down within a readable lower bound
    instead of inserting a newline that could change shell semantics.
    """

    return tuple(lines)


def _table_rows(lines: Sequence[str]) -> list[list[str]]:
    rows: list[list[str]] = []
    for line in lines:
        values = [value.strip() for value in line.strip().strip("|").split("|")]
        if all(re.fullmatch(r":?-{3,}:?", value) for value in values):
            continue
        rows.append(values)
    return rows


def _table_flowable(lines: Sequence[str], styles: dict[str, ParagraphStyle]) -> Table:
    rows = _table_rows(lines)
    if not rows:
        return Table([[]])
    columns = max(len(row) for row in rows)
    rows = [row + [""] * (columns - len(row)) for row in rows]
    data = []
    for row_index, row in enumerate(rows):
        style = styles["table-head"] if row_index == 0 else styles["table"]
        data.append([Paragraph(_inline(value, style.fontName), style) for value in row])
    widths = [CONTENT_WIDTH / columns] * columns
    table = Table(data, colWidths=widths, repeatRows=1, hAlign="LEFT")
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#195B71")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#B8CBD2")),
                ("BACKGROUND", (0, 1), (-1, -1), colors.HexColor("#F8FBFC")),
                ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.HexColor("#F8FBFC"), colors.white]),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 4),
                ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    return table


def _box_flowable(lines: Sequence[str], styles: dict[str, ParagraphStyle]) -> Table:
    content = []
    for line in lines:
        if not line:
            content.append(Spacer(1, 2))
        else:
            content.append(Paragraph(_inline(line, styles["box"].fontName), styles["box"]))
    table = Table([[content]], colWidths=[CONTENT_WIDTH], hAlign="LEFT")
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#FFF5E8")),
                ("BOX", (0, 0), (-1, -1), 0.8, colors.HexColor("#D47B2C")),
                ("LINEBEFORE", (0, 0), (0, -1), 4, colors.HexColor("#D47B2C")),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 10),
                ("RIGHTPADDING", (0, 0), (-1, -1), 8),
                ("TOPPADDING", (0, 0), (-1, -1), 7),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 7),
            ]
        )
    )
    return table


def _heading_flowable(heading: Heading, styles: dict[str, ParagraphStyle]) -> Paragraph:
    style = styles.get(f"h{min(heading.level, 4)}", styles["h4"])
    flowable = Paragraph(_inline(heading.text, style.fontName), style)
    flowable._guide_heading = heading
    return flowable


def _toc_table(entries: Sequence[tuple[int, str, int]], styles: dict[str, ParagraphStyle]) -> Table:
    header_style = ParagraphStyle("TOCHeader", parent=styles["toc"], textColor=colors.white)
    rows = [[Paragraph("Capítulo", header_style), Paragraph("Página", header_style)]]
    for level, text, page in entries:
        if level != 2:
            continue
        style = styles["toc"] if level <= 2 else styles["toc-sub"]
        rows.append(
            [
                Paragraph(_inline(text, style.fontName), style),
                Paragraph(str(page), style),
            ]
        )
    table = Table(rows, colWidths=[CONTENT_WIDTH - 22 * mm, 22 * mm], repeatRows=1)
    table.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#195B71")),
                ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
                ("GRID", (0, 0), (-1, -1), 0.3, colors.HexColor("#C2D1D6")),
                ("ALIGN", (1, 0), (1, -1), "RIGHT"),
                ("VALIGN", (0, 0), (-1, -1), "TOP"),
                ("LEFTPADDING", (0, 0), (-1, -1), 5),
                ("RIGHTPADDING", (0, 0), (-1, -1), 5),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    return table


@dataclass(frozen=True, slots=True)
class DocMetadata:
    title: str
    subtitle: str
    author: str
    subject: str
    footer: str
    edition: str
    summary_box: tuple[str, ...]


def extract_metadata(
    path: Path,
    *,
    title: str | None = None,
    subtitle: str | None = None,
    author: str = "Learn Cilium",
    subject: str | None = None,
    footer: str | None = None,
) -> DocMetadata:
    lines = path.read_text(encoding="utf-8").splitlines()

    extracted_title = ""
    extracted_subtitle = ""
    extracted_edition = ""
    summary_lines: list[str] = []
    sumario_seen = False

    for line in lines:
        stripped = line.strip()
        if not stripped:
            continue

        if stripped.startswith("## ") and stripped[3:].strip() == "Sumário":
            sumario_seen = True

        if not extracted_title and stripped.startswith("# "):
            extracted_title = stripped[2:].strip()
            continue

        if not extracted_subtitle and stripped.startswith("## ") and stripped[3:].strip() != "Sumário":
            extracted_subtitle = stripped[3:].strip()
            continue

        if not extracted_edition and "**Edição:**" in stripped:
            match = re.search(r"\*\*Edição:\*\*\s*([^·\n]+(?:·\s*[^·\n]+)?)", stripped)
            if match:
                extracted_edition = match.group(0).replace("**", "")
            else:
                extracted_edition = stripped.replace("**", "")
            continue

        if not sumario_seen and stripped.startswith(">"):
            content = stripped[1:].strip()
            if content and not content.startswith("**Resumo Executivo") and not content.startswith("**Regra"):
                summary_lines.append(content)

    doc_title = title or extracted_title or "Livro do aluno: Cilium BGP no laboratório"
    doc_subtitle = subtitle or extracted_subtitle or "Estudo guiado e prática de laboratório"
    doc_author = author or "Learn Cilium"
    doc_subject = subject or (
        "Laboratório Kubernetes, Cilium e BGP"
        if (path.resolve() == DEFAULT_SOURCE.resolve() and not subject)
        else (doc_subtitle or doc_title)
    )

    if footer:
        doc_footer = footer
    elif path.resolve() == DEFAULT_SOURCE.resolve():
        doc_footer = "Learn Cilium · Guia do estudante"
    else:
        label = doc_subtitle if doc_subtitle else doc_title
        if len(label) > 36:
            label = label[:33] + "..."
        doc_footer = f"{doc_author} · {label}"

    doc_edition = extracted_edition or "Edição 1.0 · laboratório guiado"

    if summary_lines:
        summary_tuple = tuple(summary_lines[:2])
    else:
        summary_tuple = (
            "Objetivo: observar como o Cilium anuncia PodCIDRs e um VIP de serviço por BGP.",
            "Resultado: um roteiro seguro para inspecionar o laboratório e explicar o caminho do tráfego.",
        )

    return DocMetadata(
        title=doc_title,
        subtitle=doc_subtitle,
        author=doc_author,
        subject=doc_subject,
        footer=doc_footer,
        edition=doc_edition,
        summary_box=summary_tuple,
    )


def _cover(
    styles: dict[str, ParagraphStyle],
    regular_font: str,
    bold_font: str,
    meta: DocMetadata,
) -> list[Flowable]:
    title_style = ParagraphStyle(
        "CoverTitle",
        fontName=bold_font,
        fontSize=27,
        leading=32,
        textColor=colors.HexColor("#104F65"),
        alignment=TA_CENTER,
        spaceAfter=10,
    )
    subtitle_style = ParagraphStyle(
        "CoverSubtitle",
        fontName=regular_font,
        fontSize=13,
        leading=18,
        textColor=colors.HexColor("#41606A"),
        alignment=TA_CENTER,
    )
    label_style = ParagraphStyle(
        "CoverLabel",
        fontName=bold_font,
        fontSize=9,
        leading=12,
        textColor=colors.HexColor("#D47B2C"),
        alignment=TA_CENTER,
    )
    cover_elements: list[Flowable] = [
        Spacer(1, 28 * mm),
        Paragraph(meta.author.upper(), label_style),
        Spacer(1, 6 * mm),
        Paragraph(_inline(meta.title, bold_font), title_style),
        Paragraph(_inline(meta.subtitle, regular_font), subtitle_style),
        Spacer(1, 12 * mm),
    ]
    cover_elements.append(Spacer(1, 8 * mm))

    cover_elements.extend([
        _box_flowable(meta.summary_box, styles),
        Spacer(1, 14 * mm),
        Paragraph(_inline(meta.edition, regular_font), subtitle_style),
        PageBreak(),
    ])
    return cover_elements


def _image_flowable(relative_path: str, base_dir: Path) -> Flowable | None:
    """Load a local image and scale it to the content width.

    A guide with a missing figure is incomplete.  Raising here keeps a typo in
    Markdown from silently producing a PDF with an absent topology diagram.
    """

    candidate = Path(relative_path).expanduser()
    img_path = (candidate if candidate.is_absolute() else base_dir / candidate).resolve()
    if not img_path.is_file():
        raise FileNotFoundError(
            f"Image referenced by {base_dir}: {relative_path!r} "
            f"(resolved to {img_path})"
        )
    width, height = ImageReader(str(img_path)).getSize()
    scale = min(1.0, CONTENT_WIDTH / width)
    return Image(str(img_path), width=width * scale, height=height * scale, hAlign="CENTER")


def _body_story(
    blocks: Sequence[Block], styles: dict[str, ParagraphStyle], base_dir: Path,
) -> list[Flowable]:
    story: list[Flowable] = []
    skipped_title = False
    for block in blocks:
        if block.kind == "heading":
            heading = block.value
            if isinstance(heading, Heading) and heading.level == 1 and not skipped_title:
                skipped_title = True
                continue
            story.append(_heading_flowable(heading, styles))
        elif block.kind == "paragraph":
            story.append(Paragraph(_inline(str(block.value), styles["body"].fontName), styles["body"]))
        elif block.kind == "code":
            story.append(CodeBlock(_wrapped_code(block.value)))
            story.append(Spacer(1, 5))
        elif block.kind == "image":
            image = _image_flowable(str(block.value), base_dir)
            if story and getattr(story[-1], "_guide_heading", None) is not None:
                heading = story.pop()
                story.append(KeepTogether([heading, image, Spacer(1, 5)]))
            else:
                story.append(KeepTogether([image, Spacer(1, 5)]))
        elif block.kind == "table":
            story.append(_table_flowable(block.value, styles))
            story.append(Spacer(1, 6))
        elif block.kind == "list":
            for item in block.value:
                story.append(Paragraph(_inline(item, styles["bullet"].fontName), styles["bullet"], bulletText="•"))
        elif block.kind == "numbered-list":
            for number, item in enumerate(block.value, 1):
                story.append(
                    Paragraph(
                        _inline(item, styles["bullet"].fontName),
                        styles["bullet"],
                        bulletText=f"{number}.",
                    )
                )
        elif block.kind == "box":
            story.append(_box_flowable(block.value, styles))
            story.append(Spacer(1, 6))
        elif block.kind == "rule":
            story.append(Spacer(1, 4))
    return story


def _page_decor(canvas, doc) -> None:
    canvas.saveState()
    canvas.setStrokeColor(colors.HexColor("#C2D1D6"))
    canvas.setLineWidth(0.5)
    canvas.line(LEFT_MARGIN, PAGE_HEIGHT - 12 * mm, PAGE_WIDTH - RIGHT_MARGIN, PAGE_HEIGHT - 12 * mm)
    canvas.setFont(getattr(doc, "guide_font", "Helvetica"), 7.5)
    canvas.setFillColor(colors.HexColor("#56717A"))
    footer_text = getattr(doc, "guide_footer", "Learn Cilium · Guia do estudante")
    canvas.drawString(LEFT_MARGIN, 8.5 * mm, footer_text)
    canvas.drawRightString(PAGE_WIDTH - RIGHT_MARGIN, 8.5 * mm, f"Página {doc.page}")
    canvas.restoreState()


def build_pdf(
    source: Path,
    output: Path,
    *,
    title: str | None = None,
    subtitle: str | None = None,
    author: str = "Learn Cilium",
    subject: str | None = None,
    footer: str | None = None,
) -> tuple[int, int]:
    """Render the Markdown source, iterating until TOC page numbers stabilize."""

    meta = extract_metadata(
        source,
        title=title,
        subtitle=subtitle,
        author=author,
        subject=subject,
        footer=footer,
    )
    regular_font, bold_font = _register_font()
    styles = _styles(regular_font, bold_font)
    blocks = parse_markdown(source)
    entries: tuple[tuple[int, str, int], ...] = ()
    final_doc = None
    for _ in range(4):
        story = _cover(styles, regular_font, bold_font, meta)
        story.append(Paragraph("Sumário", styles["h2"]))
        story.append(_toc_table(entries, styles))
        story.append(PageBreak())
        story.extend(_body_story(blocks, styles, source.parent))
        output.parent.mkdir(parents=True, exist_ok=True)
        doc = GuideDocTemplate(
            str(output),
            pagesize=A4,
            leftMargin=LEFT_MARGIN,
            rightMargin=RIGHT_MARGIN,
            topMargin=TOP_MARGIN,
            bottomMargin=BOTTOM_MARGIN,
            title=meta.title,
            author=meta.author,
            subject=meta.subject,
            invariant=1,
        )
        doc.guide_font = regular_font
        doc.guide_footer = meta.footer
        doc.build(story, onFirstPage=_page_decor, onLaterPages=_page_decor)
        new_entries = tuple(doc.heading_pages)
        final_doc = doc
        if new_entries == entries:
            break
        entries = new_entries
    if final_doc is None:
        raise RuntimeError("PDF generation did not produce a document")
    return final_doc.page, len(entries)


def scaffold_template(
    target: Path,
    template_path: Path | None = None,
    *,
    title: str | None = None,
    subtitle: str | None = None,
) -> int:
    template_file = template_path or (ROOT / "poc-k8s-fabric" / "docs" / "student-guide-template.md")
    if not template_file.is_file():
        candidates = [
            template_file,
            Path.cwd() / "poc-k8s-fabric" / "docs" / "student-guide-template.md",
            Path(__file__).resolve().parents[2] / "poc-k8s-fabric" / "docs" / "student-guide-template.md",
        ]
        for candidate in candidates:
            if candidate.is_file():
                template_file = candidate
                break
        else:
            raise FileNotFoundError(f"Template not found at: {template_file}")

    content = template_file.read_text(encoding="utf-8")
    if title:
        content = re.sub(r"^#\s+.*$", f"# {title}", content, count=1, flags=re.MULTILINE)
    if subtitle:
        lines = content.splitlines()
        for idx, line in enumerate(lines):
            if line.startswith("## ") and not line.startswith("## Sumário"):
                lines[idx] = f"## {subtitle}"
                break
        content = "\n".join(lines) + "\n"

    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    print(f"Scaffolded template to: {target}")
    return 0


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build the Learn Cilium student guide PDF")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE,
                        help="Source Markdown document to compile")
    parser.add_argument("--output", type=Path, default=None,
                        help="Output PDF path (defaults to docs/<source-stem>.pdf or DEFAULT_OUTPUT)")
    parser.add_argument("--title", type=str, default=None,
                        help="Document title override")
    parser.add_argument("--subtitle", type=str, default=None,
                        help="Document subtitle override")
    parser.add_argument("--author", type=str, default="Learn Cilium",
                        help="Document author (default: Learn Cilium)")
    parser.add_argument("--subject", type=str, default=None,
                        help="Document subject/topic (default derived from subtitle/title)")
    parser.add_argument("--footer", type=str, default=None,
                        help="Footer text for document pages")
    parser.add_argument("--scaffold", type=Path, default=None,
                        help="Scaffold a new laboratory markdown guide from template")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if args.scaffold is not None:
        return scaffold_template(
            args.scaffold,
            title=args.title,
            subtitle=args.subtitle,
        )

    source = args.source
    if not source.is_absolute():
        if (Path.cwd() / source).is_file():
            source = (Path.cwd() / source).resolve()
        elif (ROOT / source).is_file():
            source = (ROOT / source).resolve()

    if args.output is not None:
        output = args.output
        if not output.is_absolute():
            output = (Path.cwd() / output).resolve()
    else:
        if source == DEFAULT_SOURCE or source.resolve() == DEFAULT_SOURCE.resolve():
            output = DEFAULT_OUTPUT
        else:
            output = source.with_suffix(".pdf")

    pages, headings = build_pdf(
        source,
        output,
        title=args.title,
        subtitle=args.subtitle,
        author=args.author,
        subject=args.subject,
        footer=args.footer,
    )
    print(f"PDF OK: {output} pages={pages} headings={headings}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
