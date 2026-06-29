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
    .package(path: "../../packages/protocol/swift"),
    .package(path: "../../packages/host-core"),
    .package(path: "../../apps/helper"),
  ],
  targets: [
    .target(
      name: "SimBLECTLKit",
      dependencies: [
        .product(name: "SimBLEProtocol", package: "swift"),
        .product(name: "SimBLEHelperKit", package: "helper"),
      ]
    ),
    .executableTarget(name: "simblectl", dependencies: ["SimBLECTLKit"]),
    .testTarget(
      name: "SimBLECTLKitTests",
      dependencies: [
        "SimBLECTLKit",
        .product(name: "SimBLEHostCore", package: "host-core"),
        .product(name: "SimBLEHelperKit", package: "helper"),
      ]
    ),
  ]
)
