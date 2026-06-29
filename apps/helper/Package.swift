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
    .executable(name: "simble-menubar", targets: ["simble-menubar"]),
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
        .product(name: "SimBLEProtocol", package: "swift"),
      ],
      // Embedded via the linker, not compiled or bundled as a resource.
      exclude: ["Info.plist"],
      // Embed the Info.plist (with NSBluetoothAlwaysUsageDescription) in __TEXT,__info_plist
      // so macOS can authorize the helper's CoreBluetooth access. Path is package-relative.
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/simble-helper/Info.plist",
        ]),
      ]
    ),
    // The menubar app. It runs the same loopback bridge as the CLI behind a SwiftUI
    // MenuBarExtra. NSBluetoothAlwaysUsageDescription rides in the .app's Info.plist,
    // written by scripts/build-menubar-app.sh, so this target needs no embedded plist.
    .executableTarget(
      name: "simble-menubar",
      dependencies: [
        "SimBLEHelperKit",
        .product(name: "SimBLEHostCore", package: "host-core"),
        .product(name: "SimBLEProtocol", package: "swift"),
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
