# Page inspection

This note owns mac-ocr policy for future Vision-powered page inspection. The underlying API contracts and measurements are owned by [DetectHorizonRequest](../vision/detect-horizon-request.md), [DetectDocumentSegmentationRequest](../vision/detect-document-segmentation-request.md), and [GenerateImageFeaturePrintRequest](../vision/generate-image-feature-print-request.md).

## Current input normalization

[Image decoding](../../Sources/MacOcrCore/Input/ImageDecoding.swift) preserves EXIF orientation in [`VisionSession`](../../Sources/MacOcrCore/Runtime/VisionSession.swift). [PDF rendering](../../Sources/MacOcrCore/Input/PDFLoader.swift) produces an upright raster after applying the page's displayed rotation. Page inspection therefore examines the normalized image instead of reimplementing EXIF or PDF rotation handling.

## Adoption boundaries

Potential inspection commands may report raw Vision evidence, but do not change current behavior until a separate product decision and behavior-level coverage establish a safe action.

| Evidence | Narrow future surface | Policy that remains undecided |
| --- | --- | --- |
| Horizon angle, transform, confidence, and no-result state | `inspect horizon` | Whether and when to correct skew; no automatic rotation. |
| Document quadrilateral, mask metadata, confidence, and no-result state | `inspect document-boundary` | Perspective transform, output size, interpolation, and reading orientation; no input mutation. |
| Feature-print pairs, distances, request revision, and crop metadata | `inspect similarity` | Thresholds, grouping, duplicate labels, and any skip/delete action. |

The feature-print characterization shows why similarity must remain inspection evidence: the generated invoice template with number `1049` was much closer to number `1048` than a 90-degree rotation or unrelated image, but it is a distinct page.

## Required follow-up

Before an inspection result changes processing, characterize the intended corpus and supported runtime range:

1. Horizon detection across natural scenes, scans, receipts, blank pages, image-only PDFs, and physical quarter-turn rotations.
2. Document boundaries across perspective, keystone, shadow, glare, partial-page, multi-document, blank-page, and non-document inputs.
3. Feature-print distance distributions for repeated scans, recompression, resizing, crops, rotations, same templates with changed values, and unrelated pages.
4. Any correction transform's output dimensions, interpolation artifacts, OCR geometry, and resource use.
5. Version, architecture, crop-mode, and request-revision comparability across supported macOS releases.
