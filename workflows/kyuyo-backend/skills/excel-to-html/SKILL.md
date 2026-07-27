---
name: excel-to-html
description: >-
  Convert an Excel workbook to HTML and read that HTML instead of reading the
  .xlsx directly. ALWAYS use this skill whenever you are about to open, read,
  inspect, summarize, extract data from, or answer questions about an Excel
  file (.xlsx or .xlsm) — even when the user just says "look at this
  spreadsheet", "what's in this xlsx", "read 仕様書.xlsx", or hands you a path
  ending in .xlsx/.xlsm. Do this BEFORE any attempt to Read the binary file,
  because reading raw Excel loses merged cells, sheet boundaries, and the
  row/column grid. Triggers on spreadsheet/Excel/ワークブック/仕様書/マスタ
  files in Excel format.
---

# Excel → HTML

## Why this exists

Reading an `.xlsx` directly (binary, or a flat value dump) throws away the
things that make a spreadsheet legible: merged cells, multiple sheets, and the
row-number / column-letter grid that tells you *where* a value sits. Converting
to an HTML table keeps all of it, so you read the sheet the way a human sees it
and references like "C7" still mean something.

## What to do

Whenever you need the contents of an Excel file, **do not Read the `.xlsx`
directly**. Instead:

1. Run the bundled converter:

   ```bash
   python3 /Users/user/symphony/workflows/kyuyo-backend/skills/excel-to-html/scripts/xlsx_to_html.py "<path-to.xlsx>"
   ```

   It writes `<same-name>.html` next to the source and prints the path. To put
   the HTML elsewhere, pass a second argument:

   ```bash
   python3 /Users/user/symphony/workflows/kyuyo-backend/skills/excel-to-html/scripts/xlsx_to_html.py "in.xlsx" /tmp/out.html
   ```

2. **Read the generated `.html` file** with the Read tool. That is your view of
   the spreadsheet — work from it for any summary, extraction, or Q&A.

## What the HTML contains

- One `<table>` per worksheet, in workbook order, each titled with the sheet
  name. A header line lists how many sheets there are.
- The spreadsheet's own **row numbers** (left column) and **column letters**
  (top row) as headers, so a cell in the HTML maps back to a real Excel ref.
- **Merged cells** rendered as `rowspan` / `colspan`, matching the layout.
- Cell values using the displayed/computed value where available.
- **Strikethrough text** rendered as `<s>...</s>`, so design rows or phrases
  marked as deleted remain visible in the HTML.
- **Embedded images**, preserved (see below).

## Images

Images float over the grid, so they aren't placed inside a cell. Instead the
converter writes each one out as a real image file in a sibling
`<html-stem>_images/` directory and lists it under its sheet with the **anchor
cell** it sat at (e.g. "anchored at C3") plus the file path.

This matters for how you read them: the HTML you Read is text, so an inline
image is just a path there. **To actually see an image, Read the extracted file
itself** (e.g. `Read invoice_images/sheet0_..._C3_0.png`) — the Read tool
renders images visually. So when a sheet's content depends on an image (a
stamped seal, a logo, a screenshot, a chart pasted as a picture), open the
referenced file rather than guessing from the path.

**Pictures openpyxl can't anchor are still recovered.** openpyxl only surfaces
bitmaps it could tie to a drawing; EMF/WMF vector art, pictures inside grouped
shapes, and anything it fails to parse never reach it and would otherwise
vanish silently. As a backstop the converter also reads `xl/media/` straight
from the `.xlsx` zip and writes out every picture that wasn't already emitted
by the anchored path (deduped by content hash). These have no recoverable
sheet/cell, so they're listed at the end of the HTML under **"Additional
embedded media"**. Raster formats are previewable; EMF/WMF are exported as-is
and flagged as not viewable inline (Read can't render vector formats).

## Notes & edge cases

- **Only `.xlsx` / `.xlsm`.** openpyxl cannot read legacy `.xls`; convert it to
  `.xlsx` first (open and re-save), then run the script.
- **Formula cells** show their last cached computed value (`data_only`). If a
  file was generated programmatically and never opened in Excel, those caches
  may be empty and cells can come out blank — if you see unexpected blanks in a
  formula-heavy sheet, mention it rather than trusting the gap.
- **Large workbooks** produce large HTML. If a sheet is huge and you only need
  part of it, Read the HTML with `offset`/`limit` rather than loading it whole.
- The script needs `openpyxl` (already installed in this environment). If it's
  missing elsewhere: `pip install openpyxl`.
