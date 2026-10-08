#!/usr/bin/env python3
"""Build a readable README PDF with paginated text and Mermaid assets."""
from pathlib import Path
import re
import subprocess

from PIL import Image
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.platypus import (
    Image as PdfImage,
    KeepTogether,
    PageBreak,
    Paragraph,
    Preformatted,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "README.md"
OUTPUT = ROOT / "README.pdf"
DIAGRAM_DIR = ROOT / ".pdfgen" / "mermaid"
RENDER_DIR = ROOT / ".pdfgen" / "rendered"
PAGE_WIDTH, PAGE_HEIGHT = letter
MARGIN = 0.68 * inch
CONTENT_WIDTH = PAGE_WIDTH - 2 * MARGIN

styles = getSampleStyleSheet()
styles.add(ParagraphStyle(
    name="DocumentTitle", parent=styles["Title"], fontName="Helvetica-Bold",
    fontSize=22, leading=27, textColor=colors.HexColor("#17324D"),
    spaceAfter=18,
))
styles.add(ParagraphStyle(
    name="Section", parent=styles["Heading2"], fontName="Helvetica-Bold",
    fontSize=15, leading=19, textColor=colors.HexColor("#1B587A"),
    spaceBefore=14, spaceAfter=7, keepWithNext=True,
))
styles.add(ParagraphStyle(
    name="Subsection", parent=styles["Heading3"], fontName="Helvetica-Bold",
    fontSize=12, leading=15, textColor=colors.HexColor("#274C5E"),
    spaceBefore=10, spaceAfter=5, keepWithNext=True,
))
styles.add(ParagraphStyle(
    name="BodyReadable", parent=styles["BodyText"], fontName="Helvetica",
    fontSize=10.2, leading=14, spaceAfter=7, textColor=colors.HexColor("#20262B"),
))
styles.add(ParagraphStyle(
    name="BulletReadable", parent=styles["BodyText"], fontName="Helvetica",
    fontSize=9.8, leading=13.5, leftIndent=15, firstLineIndent=-9,
    spaceAfter=4, textColor=colors.HexColor("#20262B"),
))
styles.add(ParagraphStyle(
    name="SmallNote", parent=styles["BodyText"], fontName="Helvetica-Oblique",
    fontSize=8.5, leading=11, textColor=colors.HexColor("#53636B"),
))
styles.add(ParagraphStyle(
    name="TableText", parent=styles["BodyText"], fontName="Helvetica",
    fontSize=8.4, leading=11, textColor=colors.HexColor("#20262B"),
))
styles.add(ParagraphStyle(
    name="TableHeader", parent=styles["TableText"], fontName="Helvetica-Bold",
    textColor=colors.white,
))


def escape(text):
    """Translate the README's small Markdown subset into ReportLab paragraph markup."""
    text = text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    text = re.sub(r"`([^`]+)`", r"<font name='Courier'>\1</font>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    return text


def add_diagram(story, diagram_index):
    """Place a rendered Mermaid diagram, splitting tall images across pages."""
    source = DIAGRAM_DIR / f"diagram-{diagram_index}.png"
    if not source.exists():
        story.append(Paragraph("Diagram asset unavailable.", styles["SmallNote"]))
        return
    image = Image.open(source)
    width, height = image.size
    display_height = height * CONTENT_WIDTH / width
    slice_count = max(1, round(display_height / 650))
    slice_height = (height + slice_count - 1) // slice_count
    RENDER_DIR.mkdir(parents=True, exist_ok=True)
    story.append(PageBreak())
    for old_file in RENDER_DIR.glob(f"diagram-{diagram_index}-*.png"):
        old_file.unlink()
    for slice_index in range(slice_count):
        top = slice_index * slice_height
        bottom = min(top + slice_height, height)
        crop = image.crop((0, top, width, bottom))
        crop_path = RENDER_DIR / f"diagram-{diagram_index}-{slice_index}.png"
        crop.save(crop_path)
        display_height = (bottom - top) * CONTENT_WIDTH / width
        story.append(PdfImage(str(crop_path), width=CONTENT_WIDTH, height=display_height))
        story.append(Spacer(1, 8))
        if bottom < height:
            story.append(PageBreak())


def render_diagrams(lines):
    """Extract Mermaid fences, render PNGs, and keep assets under .pdfgen/."""
    DIAGRAM_DIR.mkdir(parents=True, exist_ok=True)
    diagram_index = 0
    line_index = 0
    while line_index < len(lines):
        if lines[line_index].strip() != "```mermaid":
            line_index += 1
            continue
        line_index += 1
        diagram_lines = []
        while line_index < len(lines) and lines[line_index].strip() != "```":
            diagram_lines.append(lines[line_index])
            line_index += 1
        source = DIAGRAM_DIR / f"diagram-{diagram_index}.mmd"
        output = DIAGRAM_DIR / f"diagram-{diagram_index}.png"
        source.write_text("\n".join(diagram_lines) + "\n", encoding="utf-8")
        subprocess.run([
            "npx", "--yes", "@mermaid-js/mermaid-cli",
            "-i", str(source), "-o", str(output), "--quiet",
        ], check=True)
        diagram_index += 1
        line_index += 1


def add_table(story, rows):
    """Render accumulated Markdown table rows with a repeated header."""
    data = []
    for row_index, row in enumerate(rows):
        cells = [Paragraph(escape(cell.strip()), styles["TableHeader" if row_index == 0 else "TableText"]) for cell in row]
        data.append(cells)
    column_count = max(len(row) for row in rows)
    widths = [CONTENT_WIDTH / column_count] * column_count
    table = Table(data, colWidths=widths, repeatRows=1, hAlign="LEFT")
    table.setStyle(TableStyle([
        ("BACKGROUND", (0, 0), (-1, 0), colors.HexColor("#1B587A")),
        ("TEXTCOLOR", (0, 0), (-1, 0), colors.white),
        ("BACKGROUND", (0, 1), (-1, -1), colors.HexColor("#F3F6F7")),
        ("ROWBACKGROUNDS", (0, 1), (-1, -1), [colors.HexColor("#F3F6F7"), colors.white]),
        ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#B8C5CA")),
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
        ("TOPPADDING", (0, 0), (-1, -1), 5),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 5),
    ]))
    story.append(table)
    story.append(Spacer(1, 8))


def build_story():
    """Convert README blocks into ReportLab flowables while preserving order."""
    lines = SOURCE.read_text(encoding="utf-8").splitlines()
    render_diagrams(lines)
    story = []
    in_code = False
    code_lines = []
    table_rows = []
    diagram_index = 0
    first_heading = True

    def flush_table():
        nonlocal table_rows
        if table_rows:
            add_table(story, table_rows)
            table_rows = []

    def flush_code():
        nonlocal code_lines
        if code_lines:
            story.append(Preformatted("\n".join(code_lines), ParagraphStyle(
                "CodeBlock", fontName="Courier", fontSize=7.2, leading=9.2,
                textColor=colors.HexColor("#1E2930"), backColor=colors.HexColor("#F1F4F5"),
                borderColor=colors.HexColor("#CBD5D8"), borderWidth=0.5,
                borderPadding=7, leftIndent=4, rightIndent=4,
            )))
            story.append(Spacer(1, 8))
            code_lines = []

    for line in lines:
        if line.startswith("```"):
            flush_table()
            if in_code:
                in_code = False
                if code_lines and code_lines[0].strip().lower() == "mermaid":
                    code_lines.pop(0)
                    flush_code()
                    add_diagram(story, diagram_index)
                    diagram_index += 1
                else:
                    flush_code()
            else:
                in_code = True
                code_lines = [line[3:].strip()]
            continue
        if in_code:
            code_lines.append(line)
            continue

        if line.startswith("|"):
            cells = [cell for cell in line.strip().strip("|").split("|")]
            if all(set(cell.strip()) <= {"-", ":", " "} for cell in cells):
                continue
            table_rows.append(cells)
            continue
        flush_table()

        if not line.strip():
            story.append(Spacer(1, 3))
        elif line.startswith("# "):
            story.append(Paragraph(escape(line[2:].strip()), styles["DocumentTitle"]))
            first_heading = False
        elif line.startswith("## "):
            story.append(Paragraph(escape(line[3:].strip()), styles["Section"]))
        elif line.startswith("### "):
            story.append(Paragraph(escape(line[4:].strip()), styles["Subsection"]))
        elif line.startswith("- "):
            story.append(Paragraph("&#8226; " + escape(line[2:].strip()), styles["BulletReadable"]))
        elif re.match(r"^\d+\. ", line):
            story.append(Paragraph(escape(line), styles["BodyReadable"]))
        else:
            story.append(Paragraph(escape(line), styles["BodyReadable"]))

    flush_table()
    if in_code:
        flush_code()
    return story


def draw_page(canvas, doc):
    """Draw the shared footer on every generated PDF page."""
    canvas.saveState()
    canvas.setStrokeColor(colors.HexColor("#D4DEE2"))
    canvas.line(MARGIN, 0.48 * inch, PAGE_WIDTH - MARGIN, 0.48 * inch)
    canvas.setFont("Helvetica", 8)
    canvas.setFillColor(colors.HexColor("#66757D"))
    canvas.drawString(MARGIN, 0.29 * inch, "GCP Windows GitOps Demo")
    canvas.drawRightString(PAGE_WIDTH - MARGIN, 0.29 * inch, f"Page {doc.page}")
    canvas.restoreState()


def main():
    """Build README.pdf from the current README and its rendered diagrams."""
    document = SimpleDocTemplate(
        str(OUTPUT), pagesize=letter, rightMargin=MARGIN, leftMargin=MARGIN,
        topMargin=0.58 * inch, bottomMargin=0.65 * inch,
        title="GCP Windows GitOps Demo",
        author="GCP Windows GitOps Demo",
    )
    document.build(build_story(), onFirstPage=draw_page, onLaterPages=draw_page)
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
