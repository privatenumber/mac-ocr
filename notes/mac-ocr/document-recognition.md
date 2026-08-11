# Document recognition

This note owns mac-ocr's integration of Vision structured-document recognition. Vision's request contract, result model, and SDK observations are owned by [RecognizeDocumentsRequest](../vision/recognize-documents-request.md).

## Current boundary

[`document`](../../Sources/MacOcrCLI/Commands/DocumentCommand.swift) is a macOS 26-only structured-document feature. It uses [`RecognizeDocumentsRequest`](../../Sources/MacOcrCore/Engines/DocumentEngine.swift) and a mac-ocr-owned result schema. Ordinary OCR and searchable-PDF generation continue to use the [legacy text-recognition path](../../Sources/MacOcrCore/Engines/OCREngine.swift).

The document command returns structured JSON and a convenient transcript. It does not render Markdown, add text to searchable PDFs, enable barcode detection, or fall back to ordinary OCR.

## Integration map

The [ordinary OCR engine](../../Sources/MacOcrCore/Engines/OCREngine.swift) uses `VNRecognizeTextRequest` to produce line-oriented observations with candidates, confidence, request revision, bounding boxes, and optional per-word geometry. `RecognizeDocumentsRequest` can supply line-oriented output through `document.text.lines`, but its contract differs:

| Current mac-ocr contract | Document-request status |
| --- | --- |
| Accurate and fast modes | Not preservable: the Vision request has no recognition-level setting. |
| Language options | Canonicalized against `supportedRecognitionLanguages`; unsupported identifiers produce `DocumentLanguageError`. |
| Maximum candidates | Supported, but the Vision default differs. |
| Custom words and language correction | Supported, with custom words ignored when correction is disabled. |
| Minimum text height | Supported, with a larger documented default than legacy text recognition. |
| ROI | When supplied, converted from `BoundingBox` through `CGRect` to Vision's `NormalizedRect`. |
| Per-line confidence and geometry | Available through recognized text lines. |
| Per-word geometry | The Vision result model exposes optional `words` and range geometry. |
| Legacy request revision field | No directly equivalent line-level field is exposed. |
| Explicit `VNRequest.cancel()` | No equivalent is exposed by the request value type. |

## Request configuration

- `DocumentOptions` defaults to one candidate per line; `DocumentEngine` assigns that value to Vision's `maximumCandidateCount`.
- Empty language options enable Vision automatic language detection. Non-empty options are canonicalized against `supportedRecognitionLanguages` before the request runs.
- `DocumentEngine` assigns language correction, custom words, minimum text height, maximum candidate count, and region of interest to `RecognizeDocumentsRequest`.
- Barcode detection is disabled for every document request.
- `DocumentEngine` throws `DocumentUnavailableError` below macOS 26 and does not invoke ordinary OCR as a fallback.

## Text output

`DocumentEngine` joins each recognized document's root `content.text.transcript` with a newline. The structured result separately retains paragraphs, tables, and lists; it does not derive plain text by concatenating those parallel collections.
