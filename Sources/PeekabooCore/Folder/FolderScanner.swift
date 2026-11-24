import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lists the images of a folder in Finder order.
///
/// `getattrlistbulk` reads names and metadata in one pass (10k entries ≈ 8 ms; FileManager with keys ≈ 31 ms) and
/// precomputed natural-sort keys order them like Finder (10k ≈ 7 ms; `localizedStandardCompare` ≈ 30 ms).
/// A FileManager listing is the fallback for file systems without bulk attributes.
public enum FolderScanner {
    /// Lower-cased filename extensions ImageIO can decode on this system.
    public static let supportedExtensions: Set<String> = {
        var result: Set<String> = []
        let identifiers = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        for identifier in identifiers {
            guard let type = UTType(identifier) else { continue }
            for ext in type.tags[.filenameExtension] ?? [] { result.insert(ext.lowercased()) }
        }
        return result
    }()

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func isSupported(name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return supportedExtensions.contains(name[name.index(after: dot)...].lowercased())
    }

    /// Image files directly inside `directory`, sorted like Finder. Hidden files are skipped; symbolic links
    /// to regular files are included.
    public static func scan(_ directory: URL) throws -> [ImageFile] {
        let entries = try listBulk(directory) ?? listWithFileManager(directory)
        return NaturalSort.sort(entries.filter { isSupported(name: $0.name) }, by: \.name)
    }

    /// What to browse for an opened URL: a folder lists its images; a file lists its siblings
    /// and returns its own index. Several files browse exactly that set.
    public static func browse(_ urls: [URL]) throws -> (files: [ImageFile], index: Int) {
        if urls.count == 1, let url = urls.first {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                return (try scan(url), 0)
            }
            let files = try scan(url.deletingLastPathComponent())
            let index = files.firstIndex { $0.url.standardizedFileURL == url.standardizedFileURL } ?? 0
            return (files, index)
        }
        let files = urls.filter(isSupported).map { url in
            ImageFile(url: url, name: url.lastPathComponent, byteSize: 0, modified: 0, fileID: 0)
        }
        return (files, 0)
    }

    // MARK: Listing

    /// Every visible regular file (or symlink to one) in `directory`, unsorted; nil when the file system does not
    /// support `getattrlistbulk`.
    public static func listBulk(_ directory: URL) throws -> [ImageFile]? {
        let path = directory.path
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        defer { close(fd) }
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_FLAGS)
            | attrgroup_t(ATTR_CMN_FILEID)
        request.fileattr = attrgroup_t(ATTR_FILE_DATALENGTH)
        let capacity = 256 << 10
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 16)
        defer { buffer.deallocate() }
        var out: [ImageFile] = []
        var first = true
        let base = path.hasSuffix("/") ? path : path + "/"
        while true {
            let count = getattrlistbulk(fd, &request, buffer, capacity, 0)
            if count < 0 {
                if first && (errno == ENOTSUP || errno == EINVAL) { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            first = false
            if count == 0 { break }
            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + 4
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size
                guard returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 else { continue }
                let nameRef = field.loadUnaligned(as: attrreference_t.self)
                let namePointer = (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                field += MemoryLayout<attrreference_t>.size
                var objectType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objectType = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var modified = timespec()
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    modified = field.loadUnaligned(as: timespec.self)
                    field += MemoryLayout<timespec>.size
                }
                var flags: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
                    flags = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var fileID: UInt64 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FILEID) != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }
                var size: Int64 = 0
                if returned.fileattr & attrgroup_t(ATTR_FILE_DATALENGTH) != 0 {
                    size = field.loadUnaligned(as: Int64.self)
                    field += 8
                }
                guard namePointer.pointee != 0x2E /* '.' */, flags & UInt32(UF_HIDDEN) == 0 else { continue }
                let name = String(cString: namePointer)
                switch objectType {
                case UInt32(VREG.rawValue):
                    out.append(ImageFile(url: URL(fileURLWithPath: base + name, isDirectory: false), name: name,
                                         byteSize: size, modified: seconds(modified), fileID: fileID))
                case UInt32(VLNK.rawValue):
                    if let file = resolvedLink(base, name) { out.append(file) }
                default:
                    continue
                }
            }
        }
        return out
    }

    /// FileManager listing with the same rules as `listBulk` (fallback, and the reference in tests).
    public static func listWithFileManager(_ directory: URL) throws -> [ImageFile] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        var out: [ImageFile] = []
        out.reserveCapacity(urls.count)
        let base = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        for url in urls {
            let name = url.lastPathComponent
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            if info.st_mode & S_IFMT == S_IFREG {
                out.append(ImageFile(url: URL(fileURLWithPath: base + name, isDirectory: false), name: name,
                                     byteSize: Int64(info.st_size), modified: seconds(info.st_mtimespec),
                                     fileID: UInt64(info.st_ino)))
            } else if info.st_mode & S_IFMT == S_IFLNK, let file = resolvedLink(base, name) {
                out.append(file)
            }
        }
        return out
    }

    private static func resolvedLink(_ base: String, _ name: String) -> ImageFile? {
        var info = stat()
        guard stat(base + name, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let url = URL(fileURLWithPath: base + name, isDirectory: false)
        return ImageFile(url: url, name: name, byteSize: Int64(info.st_size), modified: seconds(info.st_mtimespec),
                         fileID: UInt64(info.st_ino))
    }

    /// `ImageFile.modified` of a `stat` time (the listing and `FileStamp` must agree to the bit).
    static func seconds(_ time: timespec) -> Double { Double(time.tv_sec) + Double(time.tv_nsec) / 1e9 }
}
