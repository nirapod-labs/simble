// swift-tools-version: 5.10
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import PackageDescription

let package = Package(
  name: "SimBLEHostCore",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "SimBLEHostCore", targets: ["SimBLEHostCore"])
  ],
  dependencies: [
    .package(path: "../protocol/swift"),
  ],
  targets: [
    .target(
      name: "SimBLEHostCore",
      dependencies: [
        .product(name: "SimBLEProtocol", package: "swift"),
      ]
    ),
    .testTarget(
      name: "SimBLEHostCoreTests",
      dependencies: ["SimBLEHostCore"]
    ),
  ]
)
