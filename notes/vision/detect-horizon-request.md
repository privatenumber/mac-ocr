# DetectHorizonRequest

`DetectHorizonRequest` detects a horizon's tilt in an image. It is not a text-orientation or quarter-turn classifier.

## Status

- **Modern Swift API:** macOS 15.0 and later; the inspected Xcode 26.6 / macOS 26.5 SDK exposes only `.revision1`.
- **Legacy API:** `VNDetectHorizonRequest` is available from macOS 10.13, with revision 1 from macOS 10.14.

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

## Characterization

**Host:** macOS 26.5.2, arm64; Xcode 26.6 (build 17F113); macOS 26.5 SDK; modern request revision 1.

An in-memory synthetic landscape with blue sky and a green ground plane produced these results:

| Input | Observation |
| --- | --- |
| Level landscape | No horizon observation. |
| Landscape rotated +10 degrees | One observation: `-9.875000417092517` degrees, confidence `1.0`. |

The rotated result's transform was a rotation of approximately `-9.875` degrees with translation. These measurements describe this generated landscape only; they do not establish a sign convention or detection rate for photographs, scans, documents, or quarter-turn rotations.
