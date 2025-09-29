import AVFoundation
import Foundation

private let allowableRootAtomTypes: [String] = [
  "ftyp", "moov", "mdat", "stts", "stsc", "stsz", "meta", "free", "skip", "wide"
]

private let qtAtomSizeTypeSkipOffset = 8
private let stcoEntryCountOffset = 12
private let stcoTableOffset = 16

// MARK: - QTAtomMetadata

struct QTAtomMetadata {
  var offset: UInt64
  var size: UInt64
  var type: String

  var description: String {
    "Offset: \(offset), Size: \(size), Type: \(type)"
  }
}

// MARK: - MediaProcessor

class MediaProcessor {
  static func fileNeedsOptimization(url: URL) -> Bool {
    let atoms = getAtomsFor(url: url)
    for atom in atoms {
      ATLog(.debug, atom.description)
    }

    if let mdat = atoms.first(where: { $0.type == "mdat" }),
       let moov = atoms.first(where: { $0.type == "moov" })
    {
      return mdat.offset < moov.offset
    }

    return false
  }

  static func optimizeQTFile(input: URL, output: URL, completionHandler: @escaping (Bool) -> Void) {
    var rootAtoms = getAtomsFor(url: input)
    guard let mdatIndex = rootAtoms.firstIndex(where: { $0.type == "mdat" }),
          let moov = rootAtoms.first(where: { $0.type == "moov" })
    else {
      ATLog(.debug, "Could not find moov or mdat atoms")
      completionHandler(false)
      return
    }

    var finalSuccess = true
    do {
      let fh = try FileHandle(forReadingFrom: input)
      try seek(filehandle: fh, offset: moov.offset)

      var moovData = fh.readData(ofLength: Int(moov.size))
      let success = patchMoovData(data: &moovData, moov: moov)
      if success {
        rootAtoms.append(rootAtoms.remove(at: mdatIndex))
        if !FileManager.default.fileExists(atPath: output.path) {
          FileManager.default.createFile(atPath: output.path, contents: nil, attributes: nil)
        }
        if let outFh = FileHandle(forWritingAtPath: output.path) {
          for atom in rootAtoms {
            if atom.type == "moov" {
              outFh.write(moovData)
            } else {
              try seek(filehandle: fh, offset: atom.offset)
              outFh.write(fh.readData(ofLength: Int(atom.size)))
            }
          }
          outFh.closeFile()
        } else {
          ATLog(.debug, "Unable to get file handle for output target \(output.path)")
          finalSuccess = false
        }
      } else {
        finalSuccess = false
      }
      fh.closeFile()
    } catch {
      ATLog(.debug, "Error optimizing file: \(error)")
      finalSuccess = false
    }

    completionHandler(finalSuccess)
  }

  private static func getAtomsFor(url: URL) -> [QTAtomMetadata] {
    var atoms: [QTAtomMetadata] = []
    guard let fh = try? FileHandle(forReadingFrom: url) else {
      ATLog(.debug, "Could not get file handle for \(url.absoluteString)")
      return atoms
    }

    while true {
      let offset: UInt64
      do {
        offset = try MediaProcessor.offset(filehandle: fh)
      } catch {
        ATLog(.debug, "Could not get file offset for \(url.absoluteString): \(error.localizedDescription)")
        atoms = []
        break
      }
      let sizeData = fh.readData(ofLength: 4)

      // Success/break condition!
      if sizeData.count == 0 {
        break
      }

      var size: UInt64
      do {
        size = UInt64(try sizeData.bigEndianUInt32())
      } catch {
        ATLog(.debug, "Could not read atom size")
        atoms = []
        break
      }
      let type = String(data: fh.readData(ofLength: 4), encoding: .ascii) ?? ""
      if !allowableRootAtomTypes.contains(type) {
        ATLog(.debug, "Found invalid atom type: \(type)")
        atoms = []
        break
      }
      if size == 1 {
        do {
          size = try fh.readData(ofLength: 8).bigEndianUInt64()
        } catch {
          ATLog(.debug, "Could not read atom ext size")
          atoms = []
          break
        }
      }
      atoms.append(QTAtomMetadata(offset: offset, size: size, type: type))
      do {
        try seek(filehandle: fh, offset: offset + size)
      } catch {
        ATLog(.debug, "Could not seek for \(url.absoluteString): \(error.localizedDescription)")
        atoms = []
        break
      }
    }
    fh.closeFile()
    return atoms
  }

  private static func getAtoms(data: Data, offset: UInt64) -> [QTAtomMetadata] {
    var localOffset: UInt64 = offset + UInt64(qtAtomSizeTypeSkipOffset)
    var atoms: [QTAtomMetadata] = []

    while localOffset < data.count {
      var size: UInt64
      do {
        size = try UInt64(data.bigEndianUInt32At(offset: Int(localOffset)))
      } catch {
        atoms = []
        break
      }

      // Grab atom type string, which is offset from the atom start by 4 bytes and is 4 bytes in length
      let type = String(data: data.subdata(in: Range(Int(localOffset + 4)...Int(localOffset + 7))), encoding: .ascii) ??
        ""
      if size == 1 {
        do {
          // Extended size is 8 bytes after atom start
          size = try data.bigEndianUInt64At(offset: Int(localOffset + 8))
        } catch {
          atoms = []
          break
        }
      }
      atoms.append(QTAtomMetadata(offset: localOffset, size: size, type: type))
      localOffset += size
    }
    return atoms
  }

  private static func patchMoovData(data: inout Data, moov: QTAtomMetadata) -> Bool {
    let moovChildren = getAtoms(data: data, offset: 0)
    guard let trakAtom = moovChildren.first(where: { $0.type == "trak" }) else {
      ATLog(.debug, "No trak atom found")
      return false
    }

    let trakChildren = getAtoms(data: data, offset: trakAtom.offset)
    guard let mdiaAtom = trakChildren.first(where: { $0.type == "mdia" }) else {
      ATLog(.debug, "No mdia atom found")
      return false
    }

    let mdiaChildren = getAtoms(data: data, offset: mdiaAtom.offset)
    guard let minfAtom = mdiaChildren.first(where: { $0.type == "minf" }) else {
      ATLog(.debug, "No minf atom found")
      return false
    }

    let minfChildren = getAtoms(data: data, offset: minfAtom.offset)
    guard let stblAtom = minfChildren.first(where: { $0.type == "stbl" }) else {
      ATLog(.debug, "No stbl atom found")
      return false
    }

    let stblChildren = getAtoms(data: data, offset: stblAtom.offset)
    for c in stblChildren {
      if c.type == "stco" || c.type == "co64" {
        do {
          try patchChunkOffsetAtom(data: &data, atom: c, moovSize: Int(moov.size))
        } catch {
          ATLog(.debug, "Error patching chunk offset atom. \(error)")
          return false
        }
      }
    }
    return true
  }

  private static func patchChunkOffsetAtom(data: inout Data, atom: QTAtomMetadata, moovSize: Int) throws {
    let entryCount = try data.bigEndianUInt32At(offset: Int(atom.offset) + stcoEntryCountOffset)
    let tableOffset = Int(atom.offset) + stcoTableOffset
    let is64 = atom.type == "co64"
    if is64 {
      for i in 0...(Int(entryCount) - 1) {
        let entryOffset = tableOffset + (i * 8)
        var entryVal = try data.bigEndianUInt64At(offset: entryOffset)
        entryVal += UInt64(moovSize)
        entryVal = entryVal.byteSwapped
        data.replaceSubrange(Range(entryOffset...entryOffset + 7), with: &entryVal, count: 8)
      }
    } else {
      // Every 4 bytes, read UInt32, add offset, write back big-endian bytes
      for i in 0...(Int(entryCount) - 1) {
        let entryOffset = tableOffset + (i * 4)
        var entryVal = try data.bigEndianUInt32At(offset: entryOffset)
        entryVal += UInt32(moovSize)
        entryVal = entryVal.byteSwapped
        data.replaceSubrange(Range(entryOffset...entryOffset + 3), with: &entryVal, count: 4)
      }
    }
  }

  private static func seek(filehandle: FileHandle, offset: UInt64) throws {
    filehandle.seek(toFileOffset: offset)
  }

  private static func offset(filehandle: FileHandle) throws -> UInt64 {
    filehandle.offsetInFile
  }
}
