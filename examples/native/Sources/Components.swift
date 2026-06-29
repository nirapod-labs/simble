// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import SwiftUI

/// One discovered peripheral as a button row: the name and the last-seen RSSI.
struct DiscoveryRow: View {
  let device: Discovery

  var body: some View {
    HStack {
      Image(systemName: "dot.radiowaves.left.and.right")
        .foregroundStyle(.tint)
        .frame(width: 24)
      Text(device.name)
      Spacer()
      Text("\(device.rssi) dBm").foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
  }
}

/// One history line: a tinted state icon, the text, and the time.
struct HistoryRow: View {
  let line: LogLine

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon).foregroundStyle(color)
      VStack(alignment: .leading, spacing: 2) {
        Text(line.text).font(.callout)
        Text(line.time, style: .time).font(.caption2).foregroundStyle(.secondary)
      }
    }
  }

  private var icon: String {
    line.ok == true ? "checkmark.circle.fill" : line.ok == false ? "xmark.circle.fill" : "info.circle.fill"
  }
  private var color: Color {
    line.ok == true ? .green : line.ok == false ? .red : .blue
  }
}

/// A transient toast pinned to the top, auto-dismissing.
struct ToastView: View {
  let toast: Toast

  var body: some View {
    Label(toast.text, systemImage: symbol)
      .font(.subheadline.weight(.medium))
      .foregroundStyle(tint)
      .padding(.horizontal, 16).padding(.vertical, 11)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(tint.opacity(0.25)))
      .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
      .padding(.top, 8)
  }

  private var symbol: String {
    switch toast.kind {
    case .success: "checkmark.circle.fill"
    case .error: "xmark.octagon.fill"
    case .info: "info.circle.fill"
    }
  }
  private var tint: Color {
    switch toast.kind {
    case .success: .green
    case .error: .red
    case .info: .blue
    }
  }
}

extension View {
  /// Overlays an auto-dismissing toast bound to `toast`.
  func toast(_ toast: Binding<Toast?>) -> some View {
    overlay(alignment: .top) {
      if let value = toast.wrappedValue {
        ToastView(toast: value)
          .transition(.move(edge: .top).combined(with: .opacity))
          .task(id: value.id) {
            try? await Task.sleep(for: .seconds(1.9))
            withAnimation(.snappy) { toast.wrappedValue = nil }
          }
      }
    }
    .animation(.snappy, value: toast.wrappedValue)
  }
}
