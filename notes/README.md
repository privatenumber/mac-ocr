# Engineering research notes

Tracked maintainer references for Apple platform and Vision contracts that shape mac-ocr. These files are not published in the npm package.

## Ownership

Each `notes/<technology>/` folder records research about that technology alone: its API surface, configuration, version boundaries, observable behavior, and source evidence. Do not put mac-ocr policy, proposed public schemas, or implementation decisions in a technology-owned folder.

Create one file per researched Apple API. Related APIs can link to each other, but they must not duplicate claims that have one owning source note.

## Index

| Folder | Owns |
| --- | --- |
| [vision/](./vision/README.md) | Apple Vision framework contracts and request-specific research |

## Evidence

- Cite public primary sources. Prefer Apple documentation, WWDC transcripts, SDK interfaces, and sample code over summaries or third-party tutorials.
- State the inspected Xcode and SDK version when a claim comes from the installed interface rather than public documentation.
- Distinguish observed facts from inference, unknowns, and mac-ocr decisions.
- Keep current API contracts self-contained. Put change history only where it explains a current version boundary.
- Put executable contracts in `Tests/`; notes explain source evidence, ownership, and maintenance intent.

## Maintenance

When an Apple SDK or macOS release changes an API, verify the new version boundary from both the SDK interface and public documentation. Promote an API behavior into mac-ocr only after a behavior-level test covers the supported runtime range.
