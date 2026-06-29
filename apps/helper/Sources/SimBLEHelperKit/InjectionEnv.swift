// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

/// Composes the shared `DYLD_INSERT_LIBRARIES` simulator variable. Independent injection
/// tools share it instead of overwriting: each adds and removes only its own slice via
/// `composed`/`removed`. Tool-specific port and token vars stay namespaced (`SIMBLE_*`,
/// `SIMENCLAVE_*`) and are set and cleared directly.
public enum InjectionEnv {
  /// Add `dylib` to a `DYLD_INSERT_LIBRARIES` value exactly once, preserving every other entry.
  /// An entry already carrying `dylib`'s file name is replaced, so re-arming with a relocated
  /// slice path never doubles our entry.
  public static func composed(current: String?, adding dylib: String) -> String {
    let name = fileName(dylib)
    var entries = split(current).filter { fileName($0) != name }
    entries.append(dylib)
    return entries.joined(separator: ":")
  }

  /// Remove `dylib` from a `DYLD_INSERT_LIBRARIES` value, leaving every other tool's entry. Matches
  /// on the file name, so teardown finds our slice even when its absolute path has since moved or
  /// the file is gone and only its canonical name is known.
  public static func removed(current: String?, removing dylib: String) -> String {
    let name = fileName(dylib)
    return split(current).filter { fileName($0) != name }.joined(separator: ":")
  }

  private static func split(_ value: String?) -> [String] {
    (value ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
  }

  /// The last path component of an insert-list entry, the slice's file name.
  private static func fileName(_ path: String) -> String {
    String(path.split(separator: "/").last ?? Substring(path))
  }
}
