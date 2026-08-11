# Document recognition

This note owns mac-ocr's integration of Vision structured-document recognition. Vision's request contract, result model, and SDK observations are owned by [RecognizeDocumentsRequest](../vision/recognize-documents-request.md).

## Current boundary

[`document`](../../Sources/MacOcrCLI/Commands/DocumentCommand.swift) is a macOS 26-only structured-document feature. It uses [`RecognizeDocumentsRequest`](../../Sources/MacOcrCore/Engines/DocumentEngine.swift) and a mac-ocr-owned result schema. Ordinary OCR and searchable-PDF generation continue to use the [legacy text-recognition path](../../Sources/MacOcrCore/Engines/OCREngine.swift).

The document command returns structured JSON and a convenient transcript. Markdown rendering, searchable-PDF integration, barcode policy, and automatic fallback remain deferred until their behavior is characterized.

## Integration map

The [ordinary OCR engine](../../Sources/MacOcrCore/Engines/OCREngine.swift) uses `VNRecognizeTextRequest` to produce line-oriented observations with candidates, confidence, request revision, bounding boxes, and optional per-word geometry. `RecognizeDocumentsRequest` can supply line-oriented output through `document.text.lines`, but its contract differs:

| Current mac-ocr contract | Document-request status |
| --- | --- |
| Accurate and fast modes | Not preservable: the Vision request has no recognition-level setting. |
| BCP-47 language options | Requires runtime validation against `Locale.Language` input requirements. |
| Minimum confidence | Can be filtered after line recognition. |
| Maximum candidates | Supported, but the Vision default differs. |
| Custom words and language correction | Supported, with custom words ignored when correction is disabled. |
| Minimum text height | Supported, with a larger documented default than legacy text recognition. |
| ROI | Supported, but needs lower-left to top-left geometry conversion. |
| Per-line confidence and geometry | Available through recognized text lines. |
| Per-word geometry | Potentially available through `words` and range geometry; requires fixture validation. |
| Legacy request revision field | No directly equivalent line-level field is exposed. |
| Explicit `VNRequest.cancel()` | No equivalent is exposed by the request value type. |

## Current integration decisions

- Map the project ROI to Vision's lower-left normalized coordinates.
- Set the candidate count explicitly because mac-ocr defaults to one candidate and Vision defaults to three.
- Preserve language correction and custom-word behavior, including Vision's rule that custom words are ignored when correction is disabled.
- Return an unavailable error on pre-macOS 26 hosts rather than silently falling back to ordinary OCR.
- Keep document output separate from `ocr()`, `ocr.pages()`, and `searchable-pdf` schemas.

## Reading order

The [document API](../vision/recognize-documents-request.md#geometry-and-reading-order) exposes aggregate text, paragraphs, lists, tables, and nested containers through parallel access paths. mac-ocr needs a deterministic flattened-text policy before it claims natural reading order for multi-column text, lists, tables, or nested cells.

The source notes identify the line sequence as a stronger candidate than sorting blocks by geometric position, but that is an implementation hypothesis. Validate it with fixtures before making it a public-output guarantee.

## Required follow-up

Before expanding this feature, test and decide:

1. A deterministic flattened-text policy for nested containers, lists, tables, and multiple columns.
2. Candidate ordering, confidence, line and word geometry, ROI conversion, and top-left output coordinates.
3. `Task` cancellation through native service and subprocess cleanup.
4. Bounded concurrent requests before choosing a `VisionRuntime` policy.
5. Exact language support on Intel and Apple Silicon hosts, including regional language tags.
