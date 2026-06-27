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
  targets: [
    .target(name: "SimBLEHostCore"),
    .testTarget(name: "SimBLEHostCoreTests", dependencies: ["SimBLEHostCore"]),
  ]
)
