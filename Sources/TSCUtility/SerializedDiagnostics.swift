/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2020 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See http://swift.org/LICENSE.txt for license information
 See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/
import Foundation
import TSCBasic

/// Represents diagnostics serialized in a .dia file by the Swift compiler or Clang.
public struct SerializedDiagnostics {
  public enum Error: Swift.Error {
    case badMagic
    case unexpectedTopLevelRecord
    case unknownBlock
    case malformedRecord
    case noMetadataBlock
    case unexpectedSubblock
    case unexpectedRecord
    case missingInformation
  }

  private enum BlockID: UInt64 {
    case metadata = 8
    case diagnostic = 9
  }

  private enum RecordID: UInt64 {
    case version = 1
    case diagnosticInfo = 2
    case sourceRange = 3
    case flag = 4
    case category = 5
    case filename = 6
    case fixit = 7
  }

  /// The serialized diagnostics format version number.
  public var versionNumber: Int
  /// Serialized diagnostics.
  public var diagnostics: [Diagnostic]

  public init(bytes: ByteString) throws {
    var reader = Reader()
    try Bitcode.read(bytes: bytes, using: &reader)
    guard let version = reader.versionNumber else { throw Error.noMetadataBlock }
    self.versionNumber = version
    self.diagnostics = reader.diagnostics
  }
}

extension SerializedDiagnostics.Error: CustomNSError {
    public var errorUserInfo: [String : Any] {
        return [NSLocalizedDescriptionKey: "\(self)"]
    }
}

extension SerializedDiagnostics {
  public struct Diagnostic {

    public enum Level: UInt64 {
      case ignored, note, warning, error, fatal, remark
    }
    /// The diagnostic message text.
    public var text: String
    /// The level the diagnostic was emitted at.
    public var level: Level
    /// The location the diagnostic was emitted at in the source file.
    public var location: SourceLocation?
    /// The diagnostic category. Currently only Clang emits this.
    public var category: String?
    /// The corresponding diagnostic command-line flag. Currently only Clang emits this.
    public var flag: String?
    /// Ranges in the source file associated with the diagnostic.
    public var ranges: [(SourceLocation, SourceLocation)]
    /// Fix-its associated with the diagnostic.
    public var fixIts: [FixIt]

    fileprivate init(records: [BitcodeElement.Record],
                     filenameMap: inout [UInt64: String],
                     flagMap: inout [UInt64: String],
                     categoryMap: inout [UInt64: String]) throws {
      var text: String? = nil
      var level: Level? = nil
      var location: SourceLocation? = nil
      var category: String? = nil
      var flag: String? = nil
      var ranges: [(SourceLocation, SourceLocation)] = []
      var fixIts: [FixIt] = []

      for record in records {
        switch SerializedDiagnostics.RecordID(rawValue: record.id) {
        case .diagnosticInfo:
          guard record.fields.count == 8,
                case .blob(let diagnosticBlob) = record.payload
          else { throw Error.malformedRecord }

          text = String(decoding: diagnosticBlob, as: UTF8.self)
          level = Level(rawValue: record.fields[0])
          location = SourceLocation(fields: record.fields[1...4],
                                    filenameMap: filenameMap)
          category = categoryMap[record.fields[5]]
          flag = flagMap[record.fields[6]]

        case .sourceRange:
          guard record.fields.count == 8 else { throw Error.malformedRecord }

          if let start = SourceLocation(fields: record.fields[0...3],
                                        filenameMap: filenameMap),
             let end = SourceLocation(fields: record.fields[4...7],
                                      filenameMap: filenameMap) {
              ranges.append((start, end))
          }
        case .flag:
          guard record.fields.count == 2,
                case .blob(let flagBlob) = record.payload
          else { throw Error.malformedRecord }

          let flagText = String(decoding: flagBlob, as: UTF8.self)
          let diagnosticID = record.fields[0]
          flagMap[diagnosticID] = flagText

        case .category:
          guard record.fields.count == 2,
                case .blob(let categoryBlob) = record.payload
          else { throw Error.malformedRecord }

          let categoryText = String(decoding: categoryBlob, as: UTF8.self)
          let categoryID = record.fields[0]
          categoryMap[categoryID] = categoryText

        case .filename:
          guard record.fields.count == 4,
                case .blob(let filenameBlob) = record.payload
          else { throw Error.malformedRecord }

          let filenameText = String(decoding: filenameBlob, as: UTF8.self)
          let filenameID = record.fields[0]
          // record.fields[1] and record.fields[2] are no longer used.
          filenameMap[filenameID] = filenameText

        case .fixit:
          guard record.fields.count == 9,
                case .blob(let fixItBlob) = record.payload
          else { throw Error.malformedRecord }

          let fixItText = String(decoding: fixItBlob, as: UTF8.self)
          if let start = SourceLocation(fields: record.fields[0...3],
                                        filenameMap: filenameMap),
             let end = SourceLocation(fields: record.fields[4...7],
                                      filenameMap: filenameMap) {
            fixIts.append(FixIt(start: start, end: end, text: fixItText))
          }

        case .version, nil:
          throw Error.unexpectedRecord
        }
      }

      do {
        guard let text = text, let level = level else {
          throw Error.missingInformation
        }
        self.text = text
        self.level = level
        self.location = location
        self.category = category
        self.flag = flag
        self.fixIts = fixIts
        self.ranges = ranges
      }
    }
  }

  public struct SourceLocation: Equatable {
    /// The filename associated with the diagnostic.
    public var filename: String
    public var line: UInt64
    public var column: UInt64
    /// The byte offset in the source file of the diagnostic. Currently, only
    /// Clang includes this, it is set to 0 by Swift.
    public var offset: UInt64

    fileprivate init?(fields: Slice<UnsafeBufferPointer<UInt64>>,
                      filenameMap: [UInt64: String]) {
      guard let filename = filenameMap[fields[fields.startIndex]] else { return nil }
      self.filename = filename
      self.line = fields[fields.startIndex + 1]
      self.column = fields[fields.startIndex + 2]
      self.offset = fields[fields.startIndex + 3]
    }
  }

  public struct FixIt {
    /// Start location.
    public var start: SourceLocation
    /// End location.
    public var end: SourceLocation
    /// Fix-it replacement text.
    public var text: String
  }
}

extension SerializedDiagnostics {
  private struct Reader: BitstreamVisitor {
    var currentBlockID: BlockID? = nil

    var diagnostics: [Diagnostic] = []
    var versionNumber: Int? = nil
    var filenameMap = [UInt64: String]()
    var flagMap = [UInt64: String]()
    var categoryMap = [UInt64: String]()

    var currentDiagnosticRecords: [BitcodeElement.Record] = []

    func validate(signature: Bitcode.Signature) throws {
      guard signature == .init(string: "DIAG") else { throw Error.badMagic }
    }

    mutating func shouldEnterBlock(id: UInt64) throws -> Bool {
      guard let blockID = BlockID(rawValue: id) else { throw Error.unknownBlock }
      guard currentBlockID == nil else { throw Error.unexpectedSubblock }
      currentBlockID = blockID
      return true
    }

    mutating func didExitBlock() throws {
      if currentBlockID == .diagnostic {
        diagnostics.append(try Diagnostic(records: currentDiagnosticRecords,
                                          filenameMap: &filenameMap,
                                          flagMap: &flagMap,
                                          categoryMap: &categoryMap))
        currentDiagnosticRecords = []
      }
      currentBlockID = nil
    }

    mutating func visit(record: BitcodeElement.Record) throws {
      switch currentBlockID {
      case .metadata:
        guard record.id == RecordID.version.rawValue,
              record.fields.count == 1 else {
          throw Error.malformedRecord
        }
        versionNumber = Int(record.fields[0])
      case .diagnostic:
        currentDiagnosticRecords.append(record)
      case nil:
        throw Error.unexpectedTopLevelRecord
      }
    }
  }
}
