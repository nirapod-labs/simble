// swift-tools-version: 5.10
// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import PackageDescription

let package = Package(
  name: "SimBLEHelper",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "SimBLEHelperKit", targets: ["SimBLEHelperKit"]),
    .executable(name: "simble-helper", targets: ["simble-helper"]),
  ],
  dependencies: [
    .package(path: "../../packages/host-core"),
    .package(path: "../../packages/protocol/swift"),
  ],
  targets: [
    .target(
      name: "SimBLEHelperKit",
      dependencies: [
        .product(name: "SimBLEHostCore", package: "host-core"),
        .product(name: "SimBLEProtocol", package: "swift"),
      ]
    ),
    .executableTarget(
      name: "simble-helper",
      dependencies: [
        "SimBLEHelperKit",
        .product(name: "SimBLEHostCore", package: "host-core"),
      ]
    ),
    .testTarget(
      name: "SimBLEHelperKitTests",
      dependencies: [
        "SimBLEHelperKit",
        .product(name: "SimBLEHostCore", package: "host-core"),
        .product(name: "SimBLEProtocol", package: "swift"),
      ]
    ),
  ]
)
