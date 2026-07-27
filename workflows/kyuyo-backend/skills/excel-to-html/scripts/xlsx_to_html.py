#!/usr/bin/env python3
"""Convert an .xlsx/.xlsm workbook to a single readable HTML file.

Why HTML: Excel files carry structure that raw cell dumps lose — merged
cells, multiple sheets, and the row/column grid that gives values meaning.
Rendering to an HTML table preserves all of that in a form Claude can read
top-to-bottom without guessing at layout.

Preserves:
  - every worksheet (one <table> per sheet, in sheet order)
  - merged cells via rowspan/colspan
  - the spreadsheet's own row numbers and column letters as headers, so a
    reference like "C7" in the HTML maps back to the real cell
  - cell values using the displayed value where a number format applies
  - strikethrough text as <s> so deleted design rows remain visible
  - embedded images: each is written out as a real image file next to the HTML
    and referenced (with its anchor cell) so it survives the conversion

Usage:
    python3 xlsx_to_html.py <input.xlsx> [output.html]

If output.html is omitted, writes <input>.html next to the source and prints
the path on stdout. Extracted images go in a sibling "<output-stem>_images/"
directory.
"""

import hashlib
import html
import re
import sys
import zipfile
from pathlib import Path

try:
    from openpyxl import load_workbook
    from openpyxl.utils import get_column_letter
except ImportError:
    sys.exit("openpyxl is required: pip install openpyxl")


def _escape_value(value):
    # Excel stores datetimes as numbers; openpyxl already gives us datetime
    # objects, so str() is the most faithful readable form.
    if hasattr(value, "isoformat"):
        return html.escape(str(value))
    return html.escape(str(value))


def _format_rich_value(value):
    parts = []
    for run in value:
        text = getattr(run, "text", run)
        formatted = _escape_value(text)
        font = getattr(run, "font", None)
        if getattr(font, "strike", False):
            formatted = f"<s>{formatted}</s>"
        parts.append(formatted)
    return "".join(parts)


def _format_value(cell):
    value = cell.value
    if value is None:
        return ""
    if value.__class__.__name__ == "CellRichText":
        formatted = _format_rich_value(value)
    else:
        formatted = _escape_value(value)
    if getattr(cell.font, "strike", False) and formatted:
        return f"<s>{formatted}</s>"
    return formatted


# Excel's stored dimension can be wildly inflated by stray formatting or a
# single junk cell far down the sheet (we've seen dimension=...1048540 on a
# sheet whose real data ends at row 30). Trusting ws.max_row/max_column and
# iterating that rectangle materializes tens of millions of cells and blows up
# memory. So we derive the render area from cells that actually hold a value
# and cut the sheet at the first absurd vertical gap.
GAP_THRESHOLD = 1000


def _render_bounds(ws):
    """Return (max_row, max_col, dropped_note) for the area worth rendering.

    Bounds come from value-bearing cells, not the (often bogus) stored
    dimension. If there's a huge empty gap between data blocks, we stop at the
    gap and report what was left off, rather than emitting a million blank rows.
    """
    value_rows = []
    max_col = 0
    for (r, c), cell in ws._cells.items():
        if cell.value is not None:
            value_rows.append(r)
            if c > max_col:
                max_col = c
    if not value_rows:
        return 0, 0, ""

    value_rows.sort()
    last_row = value_rows[0]
    note = ""
    for prev, cur in zip(value_rows, value_rows[1:]):
        if cur - prev > GAP_THRESHOLD:
            tail = [r for r in value_rows if r > prev]
            note = (
                f"stopped at row {prev}; {len(tail)} stray value cell(s) below "
                f"(rows {tail[0]}–{tail[-1]}) skipped as likely junk/formatting"
            )
            break
        last_row = cur
    else:
        last_row = value_rows[-1]

    # Let merges that start inside the rendered area extend it a little, but
    # never far enough to reintroduce the gap we just cut.
    for rng in ws.merged_cells.ranges:
        if rng.min_row <= last_row:
            if rng.max_row - last_row < GAP_THRESHOLD:
                last_row = max(last_row, rng.max_row)
            max_col = max(max_col, min(rng.max_col, max_col if max_col else rng.max_col))
    return last_row, max_col or 1, note


def _merged_lookup(ws, max_row, max_col):
    """Map each cell coordinate to its merge role, clamped to the render area.

    Returns (anchors, covered) where anchors[(row, col)] = (rowspan, colspan)
    for top-left cells of a merge, and covered is the set of (row, col) that
    are swallowed by a merge and must be skipped when emitting <td>. Merges
    whose anchor lies outside the rendered bounds are dropped; merges that spill
    past the bounds are clamped so we never iterate beyond what we render.
    """
    anchors = {}
    covered = set()
    for rng in ws.merged_cells.ranges:
        if rng.min_row > max_row or rng.min_col > max_col:
            continue
        end_row = min(rng.max_row, max_row)
        end_col = min(rng.max_col, max_col)
        anchors[(rng.min_row, rng.min_col)] = (
            end_row - rng.min_row + 1,
            end_col - rng.min_col + 1,
        )
        for r in range(rng.min_row, end_row + 1):
            for c in range(rng.min_col, end_col + 1):
                if (r, c) != (rng.min_row, rng.min_col):
                    covered.add((r, c))
    return anchors, covered


def _safe(name):
    return re.sub(r"[^0-9A-Za-z_.-]", "_", name)


def _anchor_cell(image):
    """Best-effort Excel ref (e.g. "C3") for an embedded image's top-left."""
    anchor = image.anchor
    if isinstance(anchor, str):  # rare simple form like "A1"
        return anchor
    frm = getattr(anchor, "_from", None)
    if frm is not None:
        return f"{get_column_letter(frm.col + 1)}{frm.row + 1}"
    return "?"


def extract_images(ws, img_dir, html_dir, sheet_idx, seen):
    """Write each embedded image to img_dir; return (cell_ref, rel_path) list.

    Images float over the grid rather than living in a cell, so they can't be
    placed inside a <td> reliably. Instead we write each one out as a real file
    Claude can open with the Read tool (which renders images visually) and list
    them under the sheet with their anchor cell, preserving where they sat.

    Records the content hash of everything written into `seen`, so the
    workbook-level zip fallback can skip pictures already emitted here.
    """
    results = []
    images = getattr(ws, "_images", []) or []
    for i, image in enumerate(images):
        try:
            data = image._data()
        except Exception:
            ref = getattr(image, "ref", None)
            data = ref.getvalue() if hasattr(ref, "getvalue") else None
        if not data:
            continue
        seen.add(hashlib.sha1(data).hexdigest())
        ext = (getattr(image, "format", None) or "png").lower()
        img_dir.mkdir(parents=True, exist_ok=True)
        fname = f"sheet{sheet_idx}_{_safe(ws.title)}_{_anchor_cell(image)}_{i}.{ext}"
        (img_dir / fname).write_bytes(data)
        rel = (img_dir / fname).relative_to(html_dir).as_posix()
        results.append((_anchor_cell(image), rel))
    return results


# Raster formats the Read tool can render inline. Everything else — notably
# EMF/WMF vector pictures, which openpyxl drops silently — gets exported as-is
# and flagged as not directly viewable.
_PREVIEWABLE = {"png", "jpg", "jpeg", "gif", "bmp", "webp"}


def extract_media_fallback(src, img_dir, html_dir, seen):
    """Pull any xl/media picture openpyxl never surfaced, straight from the zip.

    openpyxl only exposes bitmaps it could anchor through a drawing; EMF/WMF
    vector art, pictures inside grouped shapes, and anything it fails to parse
    never reach ws._images and would otherwise vanish without a trace. An .xlsx
    is a zip, so we read every `xl/media/` entry directly and write out the ones
    whose bytes weren't already emitted by the anchored path (deduped by content
    hash). These have no recoverable sheet/cell, so they're listed at workbook
    level. Returns a list of (rel_path, previewable) tuples.
    """
    results = []
    try:
        zf = zipfile.ZipFile(src)
    except Exception:
        return results
    with zf:
        names = [n for n in zf.namelist()
                 if n.startswith("xl/media/") and not n.endswith("/")]
        for n in sorted(names):
            data = zf.read(n)
            if not data:
                continue
            digest = hashlib.sha1(data).hexdigest()
            if digest in seen:
                continue
            seen.add(digest)
            img_dir.mkdir(parents=True, exist_ok=True)
            fname = _safe(Path(n).name)
            (img_dir / fname).write_bytes(data)
            rel = (img_dir / fname).relative_to(html_dir).as_posix()
            ext = Path(n).suffix.lstrip(".").lower()
            results.append((rel, ext in _PREVIEWABLE))
    return results


def _render_fallback(extra):
    parts = [
        f"<h2>Additional embedded media ({len(extra)})</h2>",
        "<p><em>Pictures found in the workbook that openpyxl couldn't anchor to "
        "a cell (floating shapes, grouped shapes, EMF/WMF vector art). Listed at "
        "workbook level because their sheet/cell position isn't recoverable.</em>"
        "</p>",
        "<ul>",
    ]
    for rel, previewable in extra:
        esc = html.escape(rel)
        if previewable:
            parts.append(
                f'<li><code>{esc}</code><br>'
                f'<img src="{esc}" alt="{esc}" style="max-width:480px"></li>'
            )
        else:
            parts.append(
                f"<li><code>{esc}</code> — vector image (EMF/WMF); exported "
                f"as-is, not previewable inline</li>"
            )
    parts.append("</ul>")
    return "\n".join(parts)


def sheet_to_html(ws, img_dir, html_dir, sheet_idx, seen):
    max_row, max_col, dropped = _render_bounds(ws)
    anchors, covered = _merged_lookup(ws, max_row, max_col)

    parts = [f"<h2>{html.escape(ws.title)}</h2>"]
    if ws.sheet_state != "visible":
        parts.append(f"<p><em>(sheet state: {ws.sheet_state})</em></p>")
    if dropped:
        parts.append(f"<p><em>(note: {html.escape(dropped)})</em></p>")
    if max_row == 0:
        parts.append("<p><em>(empty sheet)</em></p>")
        images = extract_images(ws, img_dir, html_dir, sheet_idx, seen)
        return _append_images("\n".join(parts), images, ws)
    parts.append('<table border="1" cellspacing="0" cellpadding="3">')

    # Column-letter header row so positions in the HTML map back to Excel refs.
    header = ['<tr><th></th>']
    for c in range(1, max_col + 1):
        header.append(f"<th>{get_column_letter(c)}</th>")
    header.append("</tr>")
    parts.append("".join(header))

    for r in range(1, max_row + 1):
        row = [f'<tr><th>{r}</th>']
        for c in range(1, max_col + 1):
            if (r, c) in covered:
                continue
            cell = ws.cell(row=r, column=c)
            attrs = ""
            if (r, c) in anchors:
                rowspan, colspan = anchors[(r, c)]
                if rowspan > 1:
                    attrs += f' rowspan="{rowspan}"'
                if colspan > 1:
                    attrs += f' colspan="{colspan}"'
            row.append(f"<td{attrs}>{_format_value(cell)}</td>")
        row.append("</tr>")
        parts.append("".join(row))

    parts.append("</table>")

    images = extract_images(ws, img_dir, html_dir, sheet_idx, seen)
    return _append_images("\n".join(parts), images, ws)


def _append_images(body, images, ws):
    if not images:
        return body
    parts = [body, f"<h3>Images in {html.escape(ws.title)} ({len(images)})</h3>", "<ul>"]
    for cell_ref, rel in images:
        esc = html.escape(rel)
        parts.append(
            f'<li>anchored at <b>{html.escape(cell_ref)}</b>: '
            f'<code>{esc}</code><br>'
            f'<img src="{esc}" alt="image at {html.escape(cell_ref)}" '
            f'style="max-width:480px"></li>'
        )
    parts.append("</ul>")
    return "\n".join(parts)


def convert(input_path, output_path=None):
    src = Path(input_path)
    if not src.exists():
        sys.exit(f"File not found: {src}")
    if src.suffix.lower() not in (".xlsx", ".xlsm"):
        sys.exit(
            f"Unsupported extension {src.suffix!r}. openpyxl reads .xlsx/.xlsm. "
            "For legacy .xls, convert to .xlsx first (e.g. open and re-save)."
        )

    # data_only=True yields the last cached computed value of formula cells,
    # which is what a human sees in the sheet. read_only is intentionally off:
    # it disables merged-cell info, which we need to render layout faithfully.
    try:
        wb = load_workbook(src, data_only=True, rich_text=True)
    except TypeError:
        wb = load_workbook(src, data_only=True)

    out = Path(output_path) if output_path else src.with_suffix(".html")
    html_dir = out.parent
    img_dir = html_dir / f"{out.stem}_images"

    body = [
        "<!DOCTYPE html>",
        '<html><head><meta charset="utf-8">',
        f"<title>{html.escape(src.name)}</title>",
        "<style>body{font-family:sans-serif}"
        "table{border-collapse:collapse;margin-bottom:24px}"
        "th{background:#eee;font-weight:bold}"
        "td,th{border:1px solid #999;padding:3px 6px;vertical-align:top}"
        "</style></head><body>",
        f"<h1>{html.escape(src.name)}</h1>",
        f"<p>{len(wb.sheetnames)} sheet(s): "
        + ", ".join(html.escape(n) for n in wb.sheetnames)
        + "</p>",
    ]
    seen = set()
    for idx, ws in enumerate(wb.worksheets):
        body.append(sheet_to_html(ws, img_dir, html_dir, idx, seen))
    # Catch pictures openpyxl never anchored (EMF/WMF, grouped shapes, etc.)
    # by reading xl/media straight from the zip, deduped against the above.
    extra = extract_media_fallback(src, img_dir, html_dir, seen)
    if extra:
        body.append(_render_fallback(extra))
    body.append("</body></html>")

    out.write_text("\n".join(body), encoding="utf-8")
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    out = convert(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
    print(out)
