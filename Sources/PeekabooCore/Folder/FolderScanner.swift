import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Lists the images of a folder in Finder order.
/// Walking-skeleton implementation (FileManager + localizedStandardCompare);
/// the pipeline workstream replaces it with getattrlistbulk + precomputed sort keys.
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

    /// Image files directly inside `directory`, sorted like Finder.
    public static func scan(_ directory: URL) throws -> [ImageFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        var files: [ImageFile] = []
        files.reserveCapacity(urls.count)
        for url in urls where isSupported(url) {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile ?? true else { continue }
            files.append(ImageFile(
                url: url, name: url.lastPathComponent, byteSize: Int64(values?.fileSize ?? 0),
                modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                fileID: UInt64(truncatingIfNeeded: (values?.fileResourceIdentifier as? NSObject)?.hash ?? 0)))
        }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return files
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
}
