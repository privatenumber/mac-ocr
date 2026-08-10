# RecognizeDocumentsRequest

`RecognizeDocumentsRequest` is Vision's macOS 26 structured-document recognizer. It analyzes one image and returns document containers that expose text, paragraphs, tables, lists, barcodes, and data-detector matches.

## Status

- **Availability:** macOS 26.0 and later. The request is also available on iOS, iPadOS, tvOS, and visionOS 26.0 and later.
- **Current SDK inspected:** Xcode 26.6, macOS 26.5 SDK (`Vision.swiftinterface`, arm64e macOS slice).
- **Request revision:** the inspected SDK exposes only `.revision1`.
- **API family:** Swift-native `Vision.ImageProcessingRequest`, introduced with Vision's modern Swift API. It is not a `VNRequest` and cannot be submitted to `VNImageRequestHandler`.

## Sources

| Scope | Primary evidence |
| --- | --- |
| Availability, request, and supported result | [RecognizeDocumentsRequest](https://developer.apple.com/documentation/vision/recognizedocumentsrequest) |
| Document observation and root container | [DocumentObservation](https://developer.apple.com/documentation/vision/documentobservation), [DocumentObservation.Container](https://developer.apple.com/documentation/vision/documentobservation/container) |
| Text-height default | [minimumTextHeightFraction](https://developer.apple.com/documentation/vision/recognizedocumentsrequest/textrecognitionoptions-swift.struct/minimumtextheightfraction) |
| Candidate count | [maximumCandidateCount](https://developer.apple.com/documentation/vision/recognizedocumentsrequest/textrecognitionoptions-swift.struct/maximumcandidatecount) |
| Language, correction, and custom vocabulary | [recognitionLanguages](https://developer.apple.com/documentation/vision/recognizedocumentsrequest/textrecognitionoptions-swift.struct/recognitionlanguages), [useLanguageCorrection](https://developer.apple.com/documentation/vision/recognizedocumentsrequest/textrecognitionoptions-swift.struct/uselanguagecorrection), [customWords](https://developer.apple.com/documentation/vision/recognizedocumentsrequest/textrecognitionoptions-swift.struct/customwords) |
| Barcode defaults | [enabled](https://developer.apple.com/documentation/vision/recognizedocumentsrequest/barcodedetectionoptions-swift.struct/enabled), [symbologies](https://developer.apple.com/documentation/vision/recognizedocumentsrequest/barcodedetectionoptions-swift.struct/symbologies), [coalesceCompositeSymbologies](https://developer.apple.com/documentation/vision/recognizedocumentsrequest/barcodedetectionoptions-swift.struct/coalescecompositesymbologies) |
| Structured sample | [Recognizing tables within a document](https://developer.apple.com/documentation/vision/recognize-tables-within-a-document) |
| One-result current behavior and container model | [WWDC25: Read documents using the Vision framework](https://developer.apple.com/videos/play/wwdc2025/272) |
| Modern Vision API family and concurrency guidance | [WWDC24: Discover Swift enhancements in the Vision framework](https://developer.apple.com/videos/play/wwdc2024/10163) |
| Framework-level release history | [Vision updates](https://developer.apple.com/documentation/updates/vision) |

## Execution

The request is a value type. Configure it before execution, then call its async `perform` method:

```swift
@available(macOS 26.0, *)
func recognizeDocument(_ image: CGImage) async throws -> DocumentObservation.Container? {
	var request = RecognizeDocumentsRequest()
	request.textRecognitionOptions.maximumCandidateCount = 1

	return try await request.perform(on: image).first?.document
}
```

The installed SDK declares `perform(on:orientation:)` overloads for `Data`, `URL`, `CGImage`, `CIImage`, `CVPixelBuffer`, and `CMSampleBuffer`.

Apple's WWDC25 session says the current implementation returns one `DocumentObservation` per image. Treat that as current behavior, not an ordering or cardinality guarantee beyond the documented array result type.

## Request configuration

`RecognizeDocumentsRequest` exposes these relevant properties:

| Property | Contract | mac-ocr implication |
| --- | --- | --- |
| `regionOfInterest` | A normalized Vision rectangle. | Can map from mac-ocr's ROI after converting its top-left coordinates to Vision's lower-left space. |
| `textRecognitionOptions.minimumTextHeightFraction` | Minimum text height relative to image height. Apple documents a default of `1/32` (`0.03125`); increasing it reduces memory and time while ignoring smaller text. | Must be explicitly configured when compatibility with small-text OCR matters. |
| `textRecognitionOptions.automaticallyDetectLanguage` | Attempts language detection for recognition and correction. | Can map the no-language-hint path, but must be validated against the current language contract. |
| `textRecognitionOptions.recognitionLanguages` | Ordered language preferences. Apple documents two-letter ISO codes. | Document recognition accepts the request's own language identifiers, not ordinary OCR's BCP-47 contract. |
| `textRecognitionOptions.useLanguageCorrection` | Enables language correction. Disabling it returns raw recognition results with a speed/accuracy trade-off. | Maps to `--no-language-correction`. |
| `textRecognitionOptions.customWords` | Custom words take precedence over the standard lexicon and are ignored when language correction is disabled. | Maps to mac-ocr custom words, with the same caveat surfaced in documentation. |
| `textRecognitionOptions.maximumCandidateCount` | Default `3`; maximum `10`. | mac-ocr must set this explicitly because its default is `1`. |
| `barcodeDetectionOptions.enabled` | Disabled by default. | Do not enable without an explicit document-output feature. |
| `barcodeDetectionOptions.symbologies` | When barcode detection is enabled, the default scans all symbologies. | Limit only when a future product contract needs specific barcode types. |
| `barcodeDetectionOptions.coalesceCompositeSymbologies` | Defaults to `false`. | Preserve the default unless composite barcode handling is specified. |

The request does not expose `RecognizeTextRequest.RecognitionLevel`. There is no `fast` or `accurate` selector, so this request cannot preserve mac-ocr's `--fast` contract.

## Result model

Each `DocumentObservation` has a document-wide `confidence` and a root `Container`.

The root and nested containers expose these parallel views:

| Value | Meaning |
| --- | --- |
| `text` | All text in the container. |
| `title` | Optional title text. |
| `paragraphs` | Text grouped into paragraphs. |
| `tables` | Tables represented as cells, rows, and columns. |
| `lists` | Lists represented as items and marker metadata. |
| `barcodes` | Detected barcode observations when barcode detection is enabled. |

`Table.Cell.content` and `List.Item.content` are containers themselves. A cell reports closed `rowRange` and `columnRange`, allowing merged-cell representation.

`Container.Text` provides:

- `transcript`
- `lines` of `RecognizedTextObservation`
- optional `words`
- `detectedData` from Data Detection
- optional text alignment
- a normalized bounding region and range-specific bounding regions

On macOS 26, each `RecognizedTextObservation` exposes its top-candidate `transcript`, candidate list, confidence, normalized bounding region, recognized languages, title classification, text direction, and optional continuation hint (`shouldWrapToNextLine`).

## Geometry and reading order

Vision's Swift-native geometry uses normalized regions with a lower-left origin. mac-ocr emits top-left-origin boxes, so any adapter must apply the same coordinate conversion used by the legacy `VNRecognizeTextRequest` path.

The API exposes aggregate text, paragraphs, lists, tables, and nested containers as separate access paths. Do not assume that concatenating these collections creates a de-duplicated or natural reading order. A document-output feature must define its own flattening policy and test it against multi-column text, lists, tables, and nested cells.

The line sequence is a stronger candidate for plain-text ordering than sorting blocks by geometric position, but this is an implementation hypothesis that requires fixture-based validation. Apple does not document a flattening or deduplication algorithm.

## Compatibility with current mac-ocr OCR

The current engine uses `VNRecognizeTextRequest` to produce one line-oriented `Observation` with top candidates, confidence, a request revision, a bounding box, and optional per-word geometry.

`RecognizeDocumentsRequest` can potentially supply line-oriented output from `document.text.lines`, but it differs in important ways:

| Current contract | Document-request status |
| --- | --- |
| Accurate and fast modes | Not preservable: no recognition-level setting exists. |
| BCP-47 language options | Needs runtime validation against `Locale.Language` input requirements. |
| Minimum confidence | Can be filtered after line recognition. |
| Maximum candidates | Supported, but request default differs. |
| Custom words and language correction | Supported, with custom words ignored when correction is disabled. |
| Minimum text height | Supported, with a much larger documented default than mac-ocr's effective legacy behavior. |
| ROI | Supported, but coordinate conversion must be verified. |
| Per-line confidence and geometry | Available through recognized text lines. |
| Per-word geometry | Potentially available through `words` and range geometry; requires fixture validation. |
| Legacy request revision field | No directly equivalent line-level field is exposed by the inspected document model. |
| Explicit `VNRequest.cancel()` | No equivalent is exposed by the request value type. |

The current mac-ocr product has no reason to replace its ordinary OCR or searchable-PDF path with this request. The meaningful capability is structured document output.

## Known limits and unknowns

### Confirmed limits

- Requires macOS 26 or later.
- Does not support fast recognition mode.
- Barcode detection is opt-in.
- The request is designed for document structure, not as a drop-in replacement for line OCR.

### Unresolved behavior

- Whether cancelling the Swift task promptly stops `perform(on:)`.
- How the request behaves for non-document images and empty pages.
- Exact supported-language identifiers across macOS releases and architectures.
- Relative accuracy, latency, and memory use compared with `VNRecognizeTextRequest`.
- Paragraph, table, list, and aggregate-text overlap on real inputs.
- Reading order for multi-column, RTL, rotated, and nested content.
- Codable stability across macOS releases.

### Practitioner evidence

An Apple Developer Forums report describes receipt content splitting into separate paragraphs and columns. The thread has no Apple staff resolution, so it is not an API contract, but it is a useful regression fixture category: [RecognizeDocumentsRequest for receipts](https://developer.apple.com/forums/thread/788381).

On the Xcode 26.6 / macOS 26.5.2 arm64 probe host, `en` succeeds and `en-US` is rejected as unsupported. Keep this feature's language interface aligned with the identifiers reported by the document request; those include regional identifiers for some languages, so do not constrain callers to two-letter codes.

The same host recognizes a generated two-by-two ruled grid as one table with two rows and two columns. This is a release-gated mac-ocr conversion test, not a claim that arbitrary table layouts have stable cross-release semantics.

It also recognizes a generated three-item numbered list as one list with decimal marker metadata and `ALPHA`, `BETA`, and `GAMMA` item text. This is a release-gated conversion test for simple ordered lists, not a general list-layout guarantee.

## Follow-up characterization

The current release contract covers a guarded macOS 26 API, one-shot process cancellation, root transcripts, and simple generated table/list conversion. The following experiments are required before expanding that contract to claim parity, generalized reading order, or native active-request cancellation.

1. Compare document and legacy text recognition on fixtures for receipts, small text, multi-column pages, tables, lists, RTL text, rotation, and non-document images.
2. Sweep `minimumTextHeightFraction` from the documented default to the current legacy-equivalent threshold and record text loss, runtime, and memory.
3. Record exact language support on supported Intel and Apple Silicon hosts, including BCP-47 regional tags.
4. Test `Task` cancellation during `perform(on:)` and verify subprocess/service cleanup behavior.
5. Verify candidate ordering, confidence, line and word geometry, ROI conversion, and top-left coordinate output.
6. Define and test a deterministic flattened-text policy for nested containers, lists, tables, and multiple columns.
7. Encode representative observations and compare schema stability across supported macOS 26 releases.
8. Measure bounded concurrent requests before choosing a `VisionRuntime` policy for the request.

## mac-ocr adoption boundary

The safe product direction is a new macOS 26-only structured-document API and CLI command. It should have a mac-ocr-owned schema and a typed unavailable error on older systems. It should not alter `ocr()`, `ocr.pages()`, `searchable-pdf`, or their existing schemas.

Start with structured JSON and a convenient transcript. Defer Markdown rendering, searchable-PDF integration, barcode policy, and automatic fallback until the required experiments establish their behavior.
