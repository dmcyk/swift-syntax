//===------- SwiftcInvocation.swift - Utilities for invoking swiftc -------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2018 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
// This file provides the logic for invoking swiftc to parse Swift files.
//===----------------------------------------------------------------------===//

import Foundation

#if os(macOS)
import Darwin
#elseif os(Linux)
import Glibc
#endif

/// The result of process execution, containing the exit status code,
/// stdout, and stderr
struct ProcessResult {
  /// The process exit code. A non-zero exit code usually indicates failure.
  let exitCode: Int

  /// The contents of the process's stdout as Data.
  let stdoutData: Data

  /// The contents of the process's stderr as Data.
  let stderrData: Data

  /// The contents of the process's stdout, assuming the data was UTF-8 encoded.
  var stdout: String {
    return String(data: stdoutData, encoding: .utf8)!
  }

  /// The contents of the process's stderr, assuming the data was UTF-8 encoded.
  var stderr: String {
    return String(data: stderrData, encoding: .utf8)!
  }

  /// Whether or not this process had a non-zero exit code.
  var wasSuccessful: Bool {
    return exitCode == 0
  }
}

private func runCore(_ executable: URL, _ arguments: [String] = [])
    -> ProcessResult {
  let stdoutPipe = Pipe()
  var stdoutData = Data()
  let stdoutSource = DispatchSource.makeReadSource(
		fileDescriptor: stdoutPipe.fileHandleForReading.fileDescriptor)
  stdoutSource.setEventHandler {
    stdoutData.append(stdoutPipe.fileHandleForReading.availableData)
  }
  stdoutSource.resume()

  let stderrPipe = Pipe()
  var stderrData = Data()
  let stderrSource = DispatchSource.makeReadSource(
		fileDescriptor: stderrPipe.fileHandleForReading.fileDescriptor)
  stderrSource.setEventHandler {
    stderrData.append(stderrPipe.fileHandleForReading.availableData)
  }
  stderrSource.resume()

  let process = Process()
  process.launchPath = executable.path
  process.arguments = arguments
  process.standardOutput = stdoutPipe
  process.standardError = stderrPipe
  process.launch()
  process.waitUntilExit()

  return ProcessResult(exitCode: Int(process.terminationStatus),
                       stdoutData: stdoutData,
                       stderrData: stderrData)
}

/// Runs the provided executable with the provided arguments and returns the
/// contents of stdout and stderr as Data.
/// - Parameters:
///   - executable: The full file URL to the executable you're running.
///   - arguments: A list of strings to pass to the process as arguments.
/// - Returns: A ProcessResult containing stdout, stderr, and the exit code.
private func run(_ executable: URL, arguments: [String] = []) -> ProcessResult {
#if _runtime(_ObjC)
  // Use an autoreleasepool to prevent memory- and file-descriptor leaks.
  return autoreleasepool { () -> ProcessResult in
    runCore(executable, arguments)
  }
#else
  return runCore(executable, arguments)
#endif
}

enum InvocationError: Error, CustomStringConvertible {
  case couldNotFindSwiftc
  case couldNotFindSDK

  var description: String {
    switch self {
    case .couldNotFindSwiftc:
      return "could not locate swift compiler binary"
    case .couldNotFindSDK:
      return "could not locate macOS SDK"
    }
  }
}

struct SwiftcRunner {
  private static func getSearchPaths() -> [URL] {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let pathEnvVar = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let paths = pathEnvVar.split(separator: ":").map(String.init).map {
      (path: String) -> URL in
      if path.hasPrefix("/") {
        return URL(fileURLWithPath: path)
      } else {
        return cwd.appendingPathComponent(path)
      }
    }
    return paths
  }

  private static func lookupExecutablePath(filename: String) -> URL? {
    let paths = getSearchPaths()
    for path in paths {
      let url = path.appendingPathComponent(filename)
      if FileManager.default.fileExists(atPath: url.path) {
        return url
      }
    }
    return nil
  }

  private static func locateSwiftc() -> URL? {
    return lookupExecutablePath(filename: "swiftc")
  }

#if os(macOS)
  /// The location of the macOS SDK, or `nil` if it could not be found.
  private static let macOSSDK: String? = {
    let url = URL(fileURLWithPath: "/usr/bin/env")
    let result = run(url, arguments: ["xcrun", "--show-sdk-path"])
    guard result.wasSuccessful else { return nil }
    let toolPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if toolPath.isEmpty { return nil }
    return toolPath
  }()
#endif

  /// Internal static cache of the Swiftc path.
  private static let _swiftcURL: URL? = SwiftcRunner.locateSwiftc()

  /// The URL where the `swiftc` binary lies.
  private let swiftcURL: URL

  /// The source file being parsed.
  private let sourceFile: URL

  /// Creates a SwiftcRunner that will parse and emit the syntax
  /// tree for a provided source file.
  /// - Parameter sourceFile: The URL to the source file you're trying
  ///                         to parse.
  init(sourceFile: URL) throws {
    guard let url = SwiftcRunner._swiftcURL else {
      throw InvocationError.couldNotFindSwiftc
    }
    self.swiftcURL = url
    self.sourceFile = sourceFile
  }

  /// Invokes swiftc with the provided arguments.
  func invoke() throws -> ProcessResult {
    var arguments = ["-frontend", "-emit-syntax"]
    arguments.append(sourceFile.path)
#if os(macOS)
    guard let sdk = SwiftcRunner.macOSSDK else {
      throw InvocationError.couldNotFindSDK
    }
    arguments.append("-sdk")
    arguments.append(sdk)
#endif
    return run(swiftcURL, arguments: arguments)
  }
}
