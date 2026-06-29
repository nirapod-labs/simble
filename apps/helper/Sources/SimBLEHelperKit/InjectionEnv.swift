// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

/// Composes the shared `DYLD_INSERT_LIBRARIES` simulator variable. Independent injection
/// tools share it instead of overwriting: each adds and removes only its own slice via
/// `composed`/`removed`. Tool-specific port and token vars stay namespaced (`SIMBLE_*`,
/// `SIMENCLAVE_*`) and are set and cleared directly.
public enum InjectionEnv {
  /// Add `dylib` to a `DYLD_INSERT_LIBRARIES` value exactly once, preserving every other entry.
  public static func composed(current: String?, adding dylib: String) -> String {
    var entries = split(current)
    entries.removeAll { $0 == dylib }
    entries.append(dylib)
    return entries.joined(separator: ":")
  }

  /// Remove `dylib` from a `DYLD_INSERT_LIBRARIES` value, leaving every other tool's entry.
  public static func removed(current: String?, removing dylib: String) -> String {
    split(current).filter { $0 != dylib }.joined(separator: ":")
  }

  private static func split(_ value: String?) -> [String] {
    (value ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
  }
}
