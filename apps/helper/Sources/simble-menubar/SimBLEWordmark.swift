// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SwiftUI

/// The SimBLE wordmark as a system-font lockup: "Sim" in a muted medium weight and "BLE" in bold.
/// A wordmark asset under /assets can replace it.
@available(macOS 14, *)
struct SimBLEWordmark: View {
  var size: CGFloat = 17

  var body: some View {
    (Text("Sim").font(.system(size: size, weight: .medium)).foregroundStyle(.secondary)
      + Text("BLE").font(.system(size: size, weight: .bold)).foregroundStyle(.primary))
      .accessibilityLabel("SimBLE")
  }
}
