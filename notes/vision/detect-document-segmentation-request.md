# DetectDocumentSegmentationRequest

`DetectDocumentSegmentationRequest` finds one rectangular document region and a segmentation mask. Its geometry does not establish which physical edge is the document's semantic top.

## Status

- **Modern Swift API:** macOS 15.0 and later; the inspected Xcode 26.6 / macOS 26.5 SDK exposes only `.revision1`.
- **Legacy API:** `VNDetectDocumentSegmentationRequest` is available from macOS 12.0 and returns `VNRectangleObservation` values.

## Sources

| Scope | Primary evidence |
| --- | --- |
| Request and availability | [DetectDocumentSegmentationRequest](https://developer.apple.com/documentation/vision/detectdocumentsegmentationrequest) |
| Result model | [DetectedDocumentObservation](https://developer.apple.com/documentation/vision/detecteddocumentobservation) |
| Legacy request and availability | `VNDetectDocumentSegmentationRequest.h`, Xcode 26.6 / macOS 26.5 SDK |

## Result model

The modern request returns one optional `DetectedDocumentObservation`, not an array.

| Value | Contract |
| --- | --- |
| `topLeft`, `topRight`, `bottomRight`, `bottomLeft` | Normalized points that describe the detected document quadrilateral. |
| `globalSegmentationMask` | A pixel-buffer observation for the detected document mask. |
| `confidence` | A normalized `Float` in `[0, 1]`. |

The `top*` and `bottom*` labels name positions in the processed-image coordinate system. They do not report text direction, reading order, or the logical top of a physical page.

## What the request establishes

The request establishes a document boundary and mask for an input image. It does not expose:

- text-orientation or quarter-turn classification;
- document-reading direction;
- a perspective-corrected image;
- a duplicate or similarity judgment; or
- multiple documents in one input through the modern result type.

## Characterization

**Host:** macOS 26.5.2, arm64; Xcode 26.6 (build 17F113); macOS 26.5 SDK; modern request revision 1.

An in-memory page with a centered white rectangular document, page border, title, and text-like horizontal rules produced a confidence of `0.99`. Its detected normalized corners were approximately `(0.153, 0.898)`, `(0.847, 0.895)`, `(0.854, 0.102)`, and `(0.153, 0.102)`.

Rotating the same complete raster by 180 degrees produced the same confidence and corners. The named corners locate the raster rectangle, not the page's semantic reading orientation.
