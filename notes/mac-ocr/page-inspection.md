# Page inspection

This note records the current page-inspection boundary. The underlying API contracts and measurements are owned by [DetectHorizonRequest](../vision/detect-horizon-request.md), [DetectDocumentSegmentationRequest](../vision/detect-document-segmentation-request.md), and [GenerateImageFeaturePrintRequest](../vision/generate-image-feature-print-request.md).

## Current input normalization

[Image decoding](../../Sources/MacOcrCore/Input/ImageDecoding.swift) preserves EXIF orientation in [`VisionSession`](../../Sources/MacOcrCore/Runtime/VisionSession.swift). [PDF rendering](../../Sources/MacOcrCore/Input/PDFLoader.swift) produces an upright raster after applying the page's displayed rotation. Page inspection therefore examines the normalized image instead of reimplementing EXIF or PDF rotation handling.

## Current boundary

The [CLI configuration](../../Sources/MacOcrCLI/RootCommand.swift) lists only `ocr`, `document`, `searchable-pdf`, and `languages`; it has no page-inspection subcommand.

| Vision evidence | Established limit |
| --- | --- |
| Horizon angle, transform, confidence, and no-result state | It is not a text-orientation or quarter-turn classification. |
| Document quadrilateral, mask metadata, confidence, and no-result state | It does not establish a page's semantic reading orientation. |
| Feature-print pairs and distances | Vision returns no duplicate boolean, threshold, or grouping. |

The feature-print characterization contains one measured counterexample to duplicate inference: the generated invoice template with number `1049` had a distance of `0.014109100215137005` from the otherwise identical `1048` page. They are distinct pages.
