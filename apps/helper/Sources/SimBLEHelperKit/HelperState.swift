// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nirapod Labs

import Foundation

/// The running helper's discovery record: its bound loopback port and the hex of its
/// per-session capability token. The helper writes it on startup and removes it on exit;
/// `simblectl status` reads it to find and probe the bridge. The format and path are
/// defined once here, shared by writer and reader.
///
/// The file holds a loopback dev-tool capability token, not user key material. It is
/// written `0600` under the user-only application-support directory.
public struct HelperState: Equatable, Sendable {
  /// The loopback listener's bound port.
  public let port: UInt16
  /// The session capability token in lowercase hex.
  public let token: String

  /// Wrap a port and a token-hex pair.
  public init(port: UInt16, token: String) {
    self.port = port
    self.token = token
  }

  /// Base directory for the state file. Defaults to the user's application-support
  /// directory; tests set a temporary directory.
  static var directoryOverride: URL?

  /// The state-file URL under `simble/` in the base directory, creating the base from
  /// `FileManager` when no override is set.
  static func fileURL() throws -> URL {
    let base = try directoryOverride ?? FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    )
    return base.appendingPathComponent("simble", isDirectory: true)
      .appendingPathComponent("helper.json", isDirectory: false)
  }

  /// Write `{"port":N,"token":"<hex>"}` to the state file `0600`, creating its directory.
  ///
  /// - Throws: A file-system error when the directory or file cannot be written.
  public static func write(port: UInt16, token: String) throws {
    let url = try fileURL()
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let json = #"{"port":\#(port),"token":"\#(token)"}"#
    try Data(json.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// Read and parse the state file. Nil when it is absent or malformed.
  public static func read() -> HelperState? {
    guard let url = try? fileURL(),
          let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let portNumber = object["port"] as? Int, let port = UInt16(exactly: portNumber),
          let token = object["token"] as? String
    else { return nil }
    return HelperState(port: port, token: token)
  }

  /// The directory holding the state file, for a reveal-in-Finder action.
  public static func directory() throws -> URL {
    try fileURL().deletingLastPathComponent()
  }

  /// Delete the state file, ignoring an absent file.
  public static func remove() {
    guard let url = try? fileURL() else { return }
    try? FileManager.default.removeItem(at: url)
  }
}
