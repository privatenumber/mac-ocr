# Engineering research notes

Tracked maintainer references for the tools and runtime contracts that shape mac-ocr. These files are not published in the npm package.

## Ownership

Each `notes/<tool>/` folder records research about that tool alone. It may describe its own implementation, configuration, version boundaries, and observable behavior. Do not put mac-ocr policy, comparisons, or implementation decisions in a tool-owned folder.

`notes/mac-ocr/` owns cross-tool synthesis: mac-ocr behavior, policy decisions, compatibility boundaries, test matrices, and integration maps. It links to tool-owned evidence instead of duplicating it.

Use `README.md` as a short folder index. When tools have evidence for the same domain, use the same domain filename, such as `document-recognition.md` or `page-inspection.md`; do not create empty parity files without source-backed claims.

Create a tool folder when the repository makes independent, reusable claims about that tool. Incidental dependencies do not need a folder when they only explain an owning tool's implementation.

## Index

| Folder | Owns |
| --- | --- |
| [vision/](./vision/README.md) | Apple Vision framework contracts and request-specific research |
| [mac-ocr/](./mac-ocr/README.md) | mac-ocr policy, integration, and cross-tool synthesis |

## Evidence

- Cite public primary sources. Prefer immutable release tags or commit SHAs with line anchors over moving branches. For Apple APIs, cite Apple documentation, WWDC transcripts, SDK interfaces, and sample code.
- State the inspected Xcode and SDK version when a claim comes from the installed interface rather than public documentation.
- Distinguish observed facts from inference or a mac-ocr decision. Link the source that supports each fact.
- Keep current-system notes self-contained. Put historical change narratives in a tool's implementation-history section only when they explain a current constraint.
- Keep notes as current reference material, not a task tracker. Put open investigations, experiment plans, and checklists in issues or a separate working artifact.
- Put executable contracts in `Tests/`; notes explain source evidence, ownership, and maintenance intent.

## Maintenance

When updating upstream behavior, verify the cited version boundary from that tool's source and release history. Update mac-ocr policy only after the source evidence and a behavior-level test agree.
