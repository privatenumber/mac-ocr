# GenerateImageFeaturePrintRequest

`GenerateImageFeaturePrintRequest` produces one opaque feature print for an image. A caller compares two feature prints and receives a distance; Apple does not return a duplicate boolean, threshold, cluster, or page-level deduplication decision.

## Status

- **Modern Swift API:** macOS 15.0 and later. The inspected Xcode 26.6 / macOS 26.5 SDK exposes revisions 1 and 2; this host supports revision 2.
- **Legacy API:** `VNGenerateImageFeaturePrintRequest` is available from macOS 10.15. Its revision 2 is available from macOS 14.0.

## Sources

| Scope | Primary evidence |
| --- | --- |
| Request and configuration | [GenerateImageFeaturePrintRequest](https://developer.apple.com/documentation/vision/generateimagefeatureprintrequest) |
| Result model and distance | [FeaturePrintObservation](https://developer.apple.com/documentation/vision/featureprintobservation), [distance(to:)](https://developer.apple.com/documentation/vision/featureprintobservation/distance(to:)) |
| Feature-print intent and examples | [Analyzing Image Similarity with Feature Print](https://developer.apple.com/documentation/vision/analyzing-image-similarity-with-feature-print), [WWDC19: Understanding Images in Vision Framework](https://developer.apple.com/videos/play/wwdc2019/222) |
| Legacy availability and revisions | `VNGenerateImageFeaturePrintRequest.h` and `VNObservation.h`, Xcode 26.6 / macOS 26.5 SDK |

## Result model

The modern request returns one `FeaturePrintObservation`.

| Value | Contract |
| --- | --- |
| `data` | Raw feature-print data. Apple documents its element count and type, not a stable semantic format. |
| `elementCount` | Number of data elements. |
| `elementType` | Element type of the data. |
| `distance(to:)` | A throwing pairwise comparison. Shorter distance means greater similarity. |

The request's default `cropAndScaleAction` is `scaleToFill`; scaling occurs before feature-print generation. Its normalized region of interest uses a lower-left origin.

Feature prints must be comparable before computing a distance. The legacy API documents an error for non-comparable prints.

## What the request establishes

The request establishes an ordered similarity measurement between two feature prints. It does not establish:

- duplicate-page classification;
- a threshold appropriate for documents, receipts, photographs, or arbitrary user input;
- transitive clusters or groups;
- semantic equivalence; or
- a safe action such as skipping, deleting, or merging pages.

Pairwise comparison requires `n * (n - 1) / 2` distances for `n` pages.

## Characterization

**Host:** macOS 26.5.2, arm64; Xcode 26.6 (build 17F113); macOS 26.5 SDK; modern request revision 2; default `scaleToFill` crop mode.

An in-memory 500 by 700 invoice-like raster produced a 3,072-byte feature print with 768 `float` elements. The table records its distance to generated variants; these values do not define a threshold for other inputs.

| Variant | Distance |
| --- | ---: |
| Identical raster | `0.0` |
| JPEG quality `0.5` | `0.02617226541042328` |
| 60% resized raster | `0.20666156709194183` |
| Bottom-quarter crop | `0.13834653794765472` |
| 90-degree rotation | `0.7580683827400208` |
| Same template, invoice number `1049` | `0.014109100215137005` |
| Blank page | `1.4409081935882568` |
| Unrelated color-striped raster | `1.2155977487564087` |

The same-template variant is substantially closer than the transformed and unrelated variants even though its invoice number differs. A feature-print distance is therefore not an Apple duplicate classification.
