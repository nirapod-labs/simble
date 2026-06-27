// swift-tools-version: 5.10
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import PackageDescription

let package = Package(
  name: "SimBLECTL",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "SimBLECTLKit", targets: ["SimBLECTLKit"]),
    .executable(name: "simblectl", targets: ["simblectl"]),
  ],
  dependencies: [
    .package(path: "../../packages/protocol/swift")
  ],
  targets: [
    .target(
      name: "SimBLECTLKit",
      dependencies: [
        .product(name: "SimBLEProtocol", package: "swift")
      ]
    ),
    .executableTarget(name: "simblectl", dependencies: ["SimBLECTLKit"]),
    .testTarget(name: "SimBLECTLKitTests", dependencies: ["SimBLECTLKit"]),
  ]
)
