---
name: pptx
description: Presentation creation, editing, and analysis. When Claude needs to work with presentations (.pptx files) for (1) Creating new presentations, (2) Modifying or editing content, (3) Working with layouts, (4) Adding comments or speaker notes, or any other presentation tasks.
---

# PPTX Processing

## Overview

Work with PowerPoint presentations (.pptx files) for creation, editing, and analysis.

## Reading & Analysis

### Text Extraction
```bash
# Convert to markdown
pandoc presentation.pptx -t markdown -o output.md
```

### Raw XML Access
```bash
# Unpack for direct access
unzip presentation.pptx -d presentation_unpacked/
```

Access comments, speaker notes, layouts, and design elements in the unpacked XML.

## Creating New Presentations

### Using pptxgenjs (JavaScript)
```javascript
import pptxgen from 'pptxgenjs';

const pptx = new pptxgen();

const slide = pptx.addSlide();
slide.addText('Hello World', {
  x: 1, y: 1,
  fontSize: 24,
  color: '363636'
});

pptx.writeFile({ fileName: 'presentation.pptx' });
```

### Using python-pptx (Python)
```python
from pptx import Presentation
from pptx.util import Inches, Pt

prs = Presentation()
slide_layout = prs.slide_layouts[0]  # Title slide
slide = prs.slides.add_slide(slide_layout)

title = slide.shapes.title
title.text = "Hello World"

prs.save('presentation.pptx')
```

## Editing Existing Presentations

### Workflow
1. Unpack PPTX file
2. Modify XML content directly
3. Validate changes
4. Repack presentation

### Python Approach
```python
from pptx import Presentation

prs = Presentation('input.pptx')
for slide in prs.slides:
    for shape in slide.shapes:
        if shape.has_text_frame:
            for paragraph in shape.text_frame.paragraphs:
                for run in paragraph.runs:
                    run.text = run.text.replace('old', 'new')
prs.save('output.pptx')
```

## Design Guidelines

### Color Palettes
- Use consistent brand colors throughout
- Ensure sufficient contrast for readability
- Limit to 3-5 colors per presentation

### Typography
- Headlines: Bold, larger font (24-44pt)
- Body text: Regular weight (18-24pt)
- Use consistent font family

### Layout Patterns
- Title + content
- Two-column comparison
- Image with caption
- Quote/highlight slide
- Data visualization

### Visual Hierarchy
- Most important content largest/boldest
- Use whitespace effectively
- Guide viewer's eye with alignment

## Document Conversion

### PPTX to PDF
```bash
libreoffice --headless --convert-to pdf presentation.pptx
```

### Slide Thumbnails
```bash
pdftoppm -jpeg -r 150 presentation.pdf slide
```

## Dependencies

- pptxgenjs (JavaScript)
- python-pptx (Python)
- LibreOffice (conversion)
- Poppler utilities (thumbnails)