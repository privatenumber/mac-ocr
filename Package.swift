// swift-tools-version: 6.0

import PackageDescription

let package = Package(
	name: "mac-ocr",
	platforms: [
		.macOS(.v10_15),
	],
	dependencies: [
		.package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
	],
	targets: [
		.target(
			name: "MacOcrCore",
			path: "Sources/MacOcrCore"
		),
		.target(
			name: "MacOcrCLI",
			dependencies: [
				"MacOcrCore",
				.product(name: "ArgumentParser", package: "swift-argument-parser"),
			],
			path: "Sources/MacOcrCLI"
		),
		.executableTarget(
			name: "mac-ocr",
			dependencies: [
				"MacOcrCLI",
			],
			path: "Sources/mac-ocr"
		),
		.target(
			name: "MacAIKit",
			path: "Sources/MacAIKit"
		),
		.executableTarget(
			name: "name-file",
			dependencies: ["MacAIKit"],
			path: "Sources/name-file"
		),
		.executableTarget(
			name: "extract-metadata",
			dependencies: ["MacAIKit"],
			path: "Sources/extract-metadata"
		),
		.testTarget(
			name: "mac-ocrTests",
			dependencies: [
				"MacOcrCore",
				"MacOcrCLI",
				"mac-ocr",
			],
			path: "Tests/mac-ocrTests"
		),
	]
)
