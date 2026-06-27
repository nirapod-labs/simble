// swift-tools-version: 5.10
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import PackageDescription

let package = Package(
  name: "SimBLEProtocol",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "SimBLEProtocol", targets: ["SimBLEProtocol"])
  ],
  targets: [
    .target(name: "SimBLEProtocol"),
    .testTarget(name: "SimBLEProtocolTests", dependencies: ["SimBLEProtocol"]),
  ]
)
