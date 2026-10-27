#!/usr/bin/env python3
"""Build the ABNT edition (abnTeX2) of the student guide from its Markdown source.

The Markdown file stays the single source: this script checks citations,
references and numbering, converts the body with pandoc and a Lua filter, and
compiles the result with tectonic.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from typing import Sequence


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SOURCE = ROOT / "poc-k8s-fabric" / "docs" / "lab-guide-student.md"
DEFAULT_TEX = ROOT / "poc-k8s-fabric" / "docs" / "latex" / "lab-guide-student.tex"
DEFAULT_PDF = ROOT / "output" / "pdf" / "cilium-lab-student-guide.pdf"
FILTER = Path(__file__).resolve().parent / "abnt" / "guide.lua"
FIELD = re.compile(r"\*\*([^*:]+):\*\*\s*([^·]+?)\s*(?=·|$)")
YEAR = r"\[?c?\d{4}[a-z]?\]?"
MODULE = re.compile(r"^Módulo (\d+) — (.+)$")
SUBSECTION = re.compile(r"^(\d+)\.(\d+) (.+)$")
APPENDIX = re.compile(r"^Apêndice ([A-Z]) – (.+)$")
PANDOC_FORMAT = (
    "markdown+lists_without_preceding_blankline+autolink_bare_uris"
    "-subscript-superscript-tex_math_dollars-raw_html-implicit_figures"
)


class GuideError(Exception):
    """The Markdown source violates a convention the ABNT edition relies on."""


@dataclass(frozen=True, slots=True)
class Section:
    title: str
    body: str


@dataclass(frozen=True, slots=True)
class Guide:
    title: str
    subtitle: str
    fields: dict[str, str]
    sections: tuple[Section, ...]

    def section(self, title: str) -> Section:
        for section in self.sections:
            if section.title == title:
                return section
        raise GuideError(f"seção ausente: {title!r}")


def parse_guide(text: str) -> Guide:
    title_match = re.search(r"^# (.+)$", text, flags=re.MULTILINE)
    if title_match is None:
        raise GuideError("título (# ...) ausente")
    parts = re.split(r"^## (.+)$", text, flags=re.MULTILINE)
    subtitle, front = parts[1].strip(), parts[2]
    fields = {key.strip(): value.strip() for key, value in FIELD.findall(front)}
    sections = tuple(
        Section(parts[i].strip(), parts[i + 1].strip("\n")) for i in range(3, len(parts), 2)
    )
    return Guide(title_match.group(1).strip(), subtitle, fields, sections)


def _fold(value: str) -> str:
    ascii_text = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode()
    return re.sub(r"\s+", " ", ascii_text).strip().casefold()


def _sort_key(entry: str) -> tuple[str, str]:
    author = re.split(r"\*\*|\. [A-Z][a-z]", entry, maxsplit=1)[0].strip()
    lead = author or entry.replace("**", "")
    return (re.sub(r"[^\w ]", "", _fold(lead)).strip(), _fold(entry))


def reference_keys(references: str) -> list[tuple[str, str]]:
    keys = []
    for entry in (p.strip() for p in references.split("\n\n") if p.strip()):
        head = re.split(r"\*\*|\. [A-Z][a-z]", entry, maxsplit=1)[0]
        first_author = re.split(r",|\.$|\. ", head.strip(), maxsplit=1)[0]
        imprint = re.split(r"DOI:|Disponível em:", entry, maxsplit=1)[0]
        years = re.findall(r"(?<![\d/])(" + YEAR + r")\.", imprint)
        if not years:
            raise GuideError(f"referência sem data: {entry[:60]}")
        keys.append((_fold(first_author), years[-1]))
    return keys


def citation_keys(text: str) -> set[tuple[str, str]]:
    found: set[tuple[str, str]] = set()
    text = re.sub(r"\s+", " ", text)
    for content in re.findall(r"\(([^()]*" + YEAR + r")\)", text):
        for names, year in re.findall(r"(.+?),\s*(" + YEAR + r")(?:;\s*|$)", content):
            first = names.split(";")[0].replace(" et al.", "").strip()
            if re.fullmatch(r"[A-Za-z][\w\-]*(?: [A-Za-z][\w\-]*)*", first) and not first.islower():
                found.add((_fold(first), year))
    word = r"[A-Z][^\W\d_]+"
    narrative = rf"({word}(?: {word})?)(?:,? (?:e )?{word})*(?: et al\.)? \((" + YEAR + r")\)"
    for first, year in re.findall(narrative, text):
        found.add((_fold(first), year))
    return found


def check_citations(guide: Guide) -> int:
    references = reference_keys(guide.section("Referências").body)
    cited_text = "\n".join(
        s.body for s in guide.sections if s.title not in {"Referências", "Sumário"}
    )
    cited = citation_keys(cited_text)
    refs = set(references)
    problems = [f"referência não citada: {k}" for k in references if k not in cited]
    problems += [f"citação sem referência: {k}" for k in sorted(cited - refs)]
    duplicates = {k for k in references if references.count(k) > 1}
    problems += [f"referência ambígua (use a, b, c): {k}" for k in sorted(duplicates)]
    ordered = [_sort_key(e) for e in guide.section("Referências").body.split("\n\n") if e.strip()]
    if ordered != sorted(ordered):
        problems.append("referências fora de ordem alfabética")
    if problems:
        raise GuideError("\n".join(problems))
    return len(references)


def _demote(body: str, levels: int) -> str:
    return re.sub(r"^(#{3,6}) ", lambda m: "#" * (len(m.group(1)) - levels) + " ", body, flags=re.MULTILINE)


def _unnumbered_subsections(body: str) -> str:
    return re.sub(r"^(##+ .+)$", r"\1 {.unnumbered}", _demote(body, 1), flags=re.MULTILINE)


def _unnumbered_chapter(title: str) -> str:
    return (f"\\chapter*{{{title}}}\n\\addcontentsline{{toc}}{{chapter}}{{{title}}}\n"
            f"\\markboth{{{title}}}{{{title}}}\n")


def textual_markdown(guide: Guide) -> str:
    out: list[str] = []
    expected_module = 0
    appendix_open = False
    for section in guide.sections:
        title = section.title
        if title in {"Apresentação", "Sumário"}:
            continue
        if title == "Referências":
            entries = [e.strip() for e in section.body.split("\n\n") if e.strip()]
            out.append("```{=latex}\n\\postextual\n" + _unnumbered_chapter("Referências")
                       + "\\begin{referenciasabnt}\n```")
            out.extend(entries)
            out.append("```{=latex}\n\\end{referenciasabnt}\n```")
            continue
        module = MODULE.match(title)
        appendix = APPENDIX.match(title)
        if module:
            expected_module += 1
            if int(module.group(1)) != expected_module:
                raise GuideError(f"módulo fora de sequência: {title!r}")
            body = section.body
            expected_sub = 0
            for line in re.findall(r"^### (.+)$", body, flags=re.MULTILINE):
                sub = SUBSECTION.match(line)
                if sub is None:
                    raise GuideError(f"subseção sem número no Módulo {expected_module}: {line!r}")
                expected_sub += 1
                if (int(sub.group(1)), int(sub.group(2))) != (expected_module, expected_sub):
                    raise GuideError(f"subseção fora de sequência: {line!r}")
            body = re.sub(r"^### \d+\.\d+ ", "### ", body, flags=re.MULTILINE)
            out.append(f"# {module.group(2)}\n\n{_demote(body, 1)}")
        elif appendix:
            if not appendix_open:
                out.append("```{=latex}\n\\begin{apendicesenv}\n```")
                appendix_open = True
            out.append(f"# {appendix.group(2)}\n\n{_unnumbered_subsections(section.body)}")
        else:
            out.append("```{=latex}\n" + _unnumbered_chapter(title) + "```\n\n"
                       + _unnumbered_subsections(section.body))
    if appendix_open:
        out.append("```{=latex}\n\\end{apendicesenv}\n```")
    return "\n\n".join(out) + "\n"


def pandoc_latex(markdown: str) -> str:
    result = subprocess.run(
        [
            "pandoc",
            "--from", PANDOC_FORMAT,
            "--to", "latex",
            "--top-level-division=chapter",
            "--syntax-highlighting=none",
            "--wrap=preserve",
            "--lua-filter", str(FILTER),
        ],
        input=markdown,
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise GuideError(f"pandoc falhou:\n{result.stderr}")
    return result.stdout


def _tex_escape(value: str) -> str:
    special = {"\\": r"\textbackslash{}", "~": r"\textasciitilde{}", "^": r"\textasciicircum{}"}
    special.update({ch: "\\" + ch for ch in "&%$#_{}"})
    return "".join(special.get(ch, ch) for ch in value)


PREAMBLE = r"""\documentclass[12pt,openany,oneside,a4paper,chapter=TITLE,english,brazil]{abntex2}

\usepackage{fontspec}
\setmainfont{texgyretermes}[Extension=.otf,UprightFont=*-regular,BoldFont=*-bold,ItalicFont=*-italic,BoldItalicFont=*-bolditalic]
\setmonofont{DejaVuSansMono}[Extension=.ttf,Scale=0.82,BoldFont=*-Bold,ItalicFont=*-Oblique,BoldItalicFont=*-BoldOblique]
\usepackage{newunicodechar}
\newunicodechar{↔}{\ensuremath{\leftrightarrow}}
\newunicodechar{∥}{\ensuremath{\parallel}}
\usepackage{xcolor}
\usepackage{graphicx}
\graphicspath{{../}}
\usepackage{tabularx,array,booktabs}
\usepackage{placeins}
\usepackage{fvextra}
\RecustomVerbatimEnvironment{verbatim}{Verbatim}{breaklines,breakanywhere,fontsize=\footnotesize,frame=single,framesep=2mm}
\usepackage{mdframed}
\usepackage{xurl}
\urlstyle{same}
\usepackage{microtype}

\renewcommand{\ABNTEXchapterfont}{\rmfamily\bfseries\raggedright\hyphenpenalty=10000\exhyphenpenalty=10000}
\renewcommand{\ABNTEXsectionfont}{\rmfamily\bfseries\raggedright\hyphenpenalty=10000\exhyphenpenalty=10000}
\renewcommand{\ABNTEXsubsectionfont}{\rmfamily}
\renewcommand{\ABNTEXsubsubsectionfont}{\rmfamily\itshape}
\makeatletter
\renewcommand{\ABNTEXchapterupperifneeded}[1]{%
  \ifthenelse{\boolean{abntex@innonumchapter}\OR\boolean{abntex@apendiceousecao}}{}{\raggedright}%
  \ifthenelse{\boolean{ABNTEXupperchapter}}{\MakeTextUppercase{#1}}{#1}}
\makeatother
\providecommand{\tightlist}{\setlength{\itemsep}{0pt}\setlength{\parskip}{0pt}}
\providecommand{\pandocbounded}[1]{#1}

\newcommand{\quadroname}{Quadro}
\newcommand{\listofquadrosname}{Lista de quadros}
\newfloat[chapter]{quadro}{loq}{\quadroname}
\newlistof{listofquadros}{loq}{\listofquadrosname}
\newlistentry{quadro}{loq}{0}
\setfloatadjustment{quadro}{\centering}
\counterwithout{quadro}{chapter}
\renewcommand{\cftquadroname}{\quadroname\space}
\renewcommand*{\cftquadroaftersnum}{\hfill--\hfill}
\setfloatlocations{quadro}{!htbp}

\renewcommand{\topfraction}{0.9}
\renewcommand{\bottomfraction}{0.8}
\renewcommand{\textfraction}{0.07}
\renewcommand{\floatpagefraction}{0.8}
\setcounter{topnumber}{3}
\setcounter{bottomnumber}{2}
\setcounter{totalnumber}{4}
\makeatletter
\setlength{\@fptop}{0pt}
\setlength{\@fpsep}{12pt}
\setlength{\@fpbot}{0pt plus 1fil}
\makeatother

\newenvironment{referenciasabnt}
  {\begin{flushleft}\SingleSpacing\setlength{\parindent}{0pt}\setlength{\parskip}{\baselineskip}}
  {\end{flushleft}}

\titulo{@@TITULO@@}
\autor{@@AUTOR@@}
\local{@@LOCAL@@}
\data{@@ANO@@}
\preambulo{@@PREAMBULO@@}

\makeatletter
\hypersetup{
  pdftitle={\@title},
  pdfauthor={\@author},
  pdfsubject={Laboratório Kubernetes, Cilium e BGP},
  pdfkeywords={Cilium}{BGP}{Gateway API}{Kubernetes}{eBPF},
  colorlinks=true,
  linkcolor=black,
  citecolor=black,
  urlcolor=blue!50!black,
  bookmarksdepth=4
}
\makeatother

\setlrmarginsandblock{3cm}{2cm}{*}
\setulmarginsandblock{3cm}{2cm}{*}
\checkandfixthelayout
\setlength{\parindent}{1.3cm}
\setlength{\parskip}{0.2cm}
\setlength{\emergencystretch}{5em}
\tolerance=1000

\begin{document}
\selectlanguage{brazil}
\renewcommand{\listfigurename}{Lista de figuras}
\frenchspacing

\imprimircapa
\imprimirfolhaderosto

\pretextualchapter{Apresentação}
@@APRESENTACAO@@

\pdfbookmark[0]{\listfigurename}{lof}
\listoffigures*
\cleardoublepage
\pdfbookmark[0]{\listofquadrosname}{loq}
\listofquadros*
\cleardoublepage
\pdfbookmark[0]{\listtablename}{lot}
\listoftables*
\cleardoublepage
\pdfbookmark[0]{\contentsname}{toc}
\tableofcontents*
\cleardoublepage

\textual
\OnehalfSpacing

@@CORPO@@

\end{document}
"""


def render_tex(guide: Guide) -> str:
    fields = guide.fields
    subtitle = guide.subtitle[0].lower() + guide.subtitle[1:]
    title = f"{guide.title}: {subtitle}"
    preambulo = f"Edição {fields.get('Edição', '1.0')}."
    if audience := fields.get("Público-alvo"):
        preambulo += f" Público-alvo: {audience}."
    apresentacao = pandoc_latex(guide.section("Apresentação").body)
    corpo = pandoc_latex(textual_markdown(guide))
    replacements = {
        "@@TITULO@@": _tex_escape(title),
        "@@AUTOR@@": _tex_escape(fields.get("Autor", "Learn Cilium")),
        "@@LOCAL@@": _tex_escape(fields.get("Local", "[S. l.]")),
        "@@ANO@@": _tex_escape(fields.get("Ano", "")),
        "@@PREAMBULO@@": _tex_escape(preambulo),
        "@@APRESENTACAO@@": apresentacao,
        "@@CORPO@@": corpo,
    }
    tex = PREAMBLE
    for marker, value in replacements.items():
        tex = tex.replace(marker, value)
    return tex


def compile_pdf(tex_path: Path, pdf_path: Path) -> None:
    if shutil.which("tectonic") is None:
        raise GuideError("tectonic não encontrado no PATH (brew install tectonic)")
    result = subprocess.run(
        ["tectonic", "-X", "compile", tex_path.name],
        cwd=tex_path.parent,
        capture_output=True,
        text=True,
        check=False,
    )
    log = result.stdout + result.stderr
    if result.returncode != 0:
        raise GuideError(f"tectonic falhou:\n{log[-4000:]}")
    missing = sorted(set(re.findall(r"Missing character: There is no (\S+) \((U\+[0-9A-F]+)\)", log)))
    if missing:
        raise GuideError(f"glifos ausentes na fonte: {missing}")
    built = tex_path.with_suffix(".pdf")
    pdf_path.parent.mkdir(parents=True, exist_ok=True)
    built.replace(pdf_path)


def parse_args(argv: Sequence[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build the ABNT (abnTeX2) edition of the student guide")
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--tex", type=Path, default=DEFAULT_TEX)
    parser.add_argument("--pdf", type=Path, default=DEFAULT_PDF)
    parser.add_argument("--check-only", action="store_true",
                        help="validate citations, references and numbering without writing files")
    parser.add_argument("--no-pdf", action="store_true", help="write the .tex without compiling it")
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        guide = parse_guide(args.source.read_text(encoding="utf-8"))
        count = check_citations(guide)
        textual_markdown(guide)
        if args.check_only:
            print(f"ABNT OK: {count} referências citadas, numeração consistente")
            return 0
        args.tex.parent.mkdir(parents=True, exist_ok=True)
        args.tex.write_text(render_tex(guide), encoding="utf-8")
        print(f"LaTeX OK: {args.tex}")
        if not args.no_pdf:
            compile_pdf(args.tex, args.pdf)
            print(f"PDF ABNT OK: {args.pdf}")
    except GuideError as error:
        print(f"ERRO: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
