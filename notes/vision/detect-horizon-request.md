# DetectHorizonRequest

`DetectHorizonRequest` detects a horizon's tilt in an image. Its output can support a future scene-skew inspection feature, but it is not a text-orientation or quarter-turn classifier.

## Status

- **Modern Swift API:** macOS 15.0 and later; the inspected Xcode 26.6 / macOS 26.5 SDK exposes only `.revision1`.
- **Legacy API:** `VNDetectHorizonRequest` is available from macOS 10.13, with revision 1 from macOS 10.14.
- **Current mac-ocr floor:** macOS 10.15. Any product use needs an availability-gated legacy path below macOS 15.

## Sources

| Scope | Primary evidence |
| --- | --- |
| Request and availability | [DetectHorizonRequest](https://developer.apple.com/documentation/vision/detecthorizonrequest) |
| Result model | [HorizonObservation](https://developer.apple.com/documentation/vision/horizonobservation) |
| Legacy request and availability | `VNDetectHorizonRequest.h`, Xcode 26.6 / macOS 26.5 SDK |
| Legacy result model | `VNObservation.h`, Xcode 26.6 / macOS 26.5 SDK |

## Result model

The modern request returns one optional `HorizonObservation`, not an array. A missing observation means Vision did not detect a horizon.

| Value | Contract |
| --- | --- |
| `angle` | `Measurement<UnitAngle>` for the observed horizon angle. |
| `transform` | `CGAffineTransform` for the detected horizon. Apple says to apply its inverse to orient the image upright and level the detected horizon. |
| `confidence` | A normalized `Float` in `[0, 1]`. |

The legacy request returns an optional array of `VNHorizonObservation` values. Its `angle` is a `CGFloat`; its image-coordinate `transform` is converted for a specific image size with `transformForImageWidth:height:` on macOS 13 and later.

## What the request establishes

The request establishes a geometric correction for a detected horizon. It does not expose:

- a document's reading orientation;
- a `0`, `90`, `180`, or `270` degree classification;
- a language, text-direction, or page-top observation; or
- a result for every image.

`mac-ocr` already honors image EXIF orientation when creating `VisionSession`, and renders PDF pages in an upright context. Horizon detection would therefore inspect remaining scene skew, not replace current orientation normalization.

## Characterization

**Host:** macOS 26.5.2, arm64; Xcode 26.6 (build 17F113); macOS 26.5 SDK; modern request revision 1.

An in-memory synthetic landscape with blue sky and a green ground plane produced these results:

| Input | Observation |
| --- | --- |
| Level landscape | No horizon observation. |
| Landscape rotated +10 degrees | One observation: `-9.875000417092517` degrees, confidence `1.0`. |

The rotated result's transform was a rotation of approximately `-9.875` degrees with translation. This confirms that the request can report small landscape skew in this controlled input. It does not establish a sign convention or a detection-rate guarantee for photographs, scans, documents, or quarter-turn rotations.

## Follow-up characterization

Before product adoption, measure the following on generated and retained test fixtures with the request revision and orientation recorded:

1. Level and `+/-3`, `+/-10`, `+/-20` degree natural scenes.
2. Receipts, printed pages, scans with borders, blank pages, and image-only PDFs.
3. Physical `90`, `180`, and `270` degree rotations, separately from EXIF orientation tags.
4. The effect of applying the documented inverse transform on output bounds, resolution, and OCR geometry.
5. Confidence distributions and no-result rates across supported macOS releases and architectures.

## mac-ocr adoption boundary

The narrow future surface is an opt-in `inspect horizon` result that reports Vision's angle, transform, confidence, request revision, and no-result state. It must not auto-rotate input or change the behavior of `ocr()`, `ocr.pages()`, `document`, or `searchable-pdf` without a separate product decision and behavior-level coverage.
