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

| Property | Contract |
| --- | --- |
| `regionOfInterest` | A normalized Vision rectangle. |
| `textRecognitionOptions.minimumTextHeightFraction` | Minimum text height relative to image height. Apple documents a default of `1/32` (`0.03125`); increasing it reduces memory and time while ignoring smaller text. |
| `textRecognitionOptions.automaticallyDetectLanguage` | Attempts language detection for recognition and correction. |
| `textRecognitionOptions.recognitionLanguages` | Ordered language preferences. Apple documents two-letter ISO codes. |
| `textRecognitionOptions.useLanguageCorrection` | Enables language correction. Disabling it returns raw recognition results with a speed/accuracy trade-off. |
| `textRecognitionOptions.customWords` | Custom words take precedence over the standard lexicon and are ignored when language correction is disabled. |
| `textRecognitionOptions.maximumCandidateCount` | Default `3`; maximum `10`. |
| `barcodeDetectionOptions.enabled` | Disabled by default. |
| `barcodeDetectionOptions.symbologies` | When barcode detection is enabled, the default scans all symbologies. |
| `barcodeDetectionOptions.coalesceCompositeSymbologies` | Defaults to `false`. |

The request does not expose `RecognizeTextRequest.RecognitionLevel`. There is no `fast` or `accurate` selector.

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

Vision's Swift-native geometry uses normalized regions with a lower-left origin.

The API exposes aggregate text, paragraphs, lists, tables, and nested containers as separate access paths. Do not assume that concatenating these collections creates a de-duplicated or natural reading order. Apple does not document a flattening or deduplication algorithm.

## Limits

- Requires macOS 26 or later.
- Does not support fast recognition mode.
- Barcode detection is opt-in.
- The request is designed for document structure, not as a drop-in replacement for line OCR.

## Characterization

**Host:** macOS 26.5.2, arm64; Xcode 26.6 (build 17F113); macOS 26.5 SDK; request revision 1.

On the Xcode 26.6 / macOS 26.5.2 arm64 probe host, `en` succeeds and `en-US` is rejected as unsupported. The request's supported identifiers include regional identifiers for some languages, so callers should not assume two-letter codes are sufficient.

The same host recognizes a generated two-by-two ruled grid as one table with two rows and two columns. This is an observed generated input, not a claim that arbitrary table layouts have stable cross-release semantics.

It also recognizes a generated three-item numbered list as one list with decimal marker metadata and `ALPHA`, `BETA`, and `GAMMA` item text. These measurements describe the generated inputs only.
