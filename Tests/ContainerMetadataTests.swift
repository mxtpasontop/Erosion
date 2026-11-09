import Foundation
import Darwin

// Compile with the production InfoHelpers.swift. Only device access is stubbed;
// xattrs and metadata plists use real temporary filesystem fixtures on macOS.
enum FSPaths {
    static let appBundles = "/var/containers/Bundle/Application"
    static let appContainers = "/var/mobile/Containers/Data/Application"
}

struct TestAccess {
    func grantAccess(path: String) -> (Bool, Int64, String) { (true, 0, "test") }
}
let wq = TestAccess()
let group = "test.container.metadata"
var stagedMetadata: [String: Data] = [:]
var activePaths: [Int64: String] = [:]
var releasedHandles = 0

func worse_query(_ path: String, _ group: String, _ alternateFlags: Bool, _ createDirectory: Bool) -> Int64 {
    guard let data = stagedMetadata.removeValue(forKey: path) else { return -1 }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        activePaths[1] = path
        return 1
    } catch { return -1 }
}

func worse_query_release(_ handle: Int64) {
    if let path = activePaths.removeValue(forKey: handle) {
        try? FileManager.default.removeItem(atPath: path)
        releasedHandles += 1
    }
}

@main
struct ContainerMetadataTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let expected = "com.apple.PosterBoard"
        let hidden = ".com.apple.mobile_container_manager.metadata.plist"
        let visible = "com.apple.mobile_container_manager.metadata.plist"
        let metadata = try PropertyListSerialization.data(
            fromPropertyList: ["MCMMetadataIdentifier": expected], format: .binary, options: 0)

        func container(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        func setIdentifier(_ bytes: [UInt8], at url: URL) throws {
            let result = bytes.withUnsafeBytes {
                setxattr(url.path, "com.apple.containermanager.identifier", $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        }
        func expect(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }

        let hiddenContainer = try container("hidden-plist")
        try metadata.write(to: hiddenContainer.appendingPathComponent(hidden))
        expect(getBIDFromXattr(hiddenContainer) == nil, "Fixture must reproduce ENOATTR")
        expect(folderLabel(url: hiddenContainer) == expected, "ENOATTR must fall back to hidden plist")

        let visibleContainer = try container("visible-plist")
        try Data("invalid plist".utf8).write(to: visibleContainer.appendingPathComponent(hidden))
        try metadata.write(to: visibleContainer.appendingPathComponent(visible))
        expect(folderLabel(url: visibleContainer) == expected, "Corrupt hidden plist must not block visible plist")

        let xattrContainer = try container("xattr")
        try setIdentifier(Array("com.example.xattr".utf8), at: xattrContainer)
        try metadata.write(to: xattrContainer.appendingPathComponent(hidden))
        expect(folderLabel(url: xattrContainer) == "com.example.xattr", "Existing xattr must take precedence")

        let invalidXattr = try container("invalid-xattr")
        try setIdentifier([0xff, 0xfe], at: invalidXattr)
        try metadata.write(to: invalidXattr.appendingPathComponent(hidden))
        expect(folderLabel(url: invalidXattr) == expected, "Invalid UTF-8 xattr must fall back without crashing")

        let emptyXattr = try container("empty-xattr")
        try setIdentifier([0], at: emptyXattr)
        try metadata.write(to: emptyXattr.appendingPathComponent(hidden))
        expect(folderLabel(url: emptyXattr) == expected, "Empty xattr must fall back")

        let protectedContainer = try container("access-lifetime")
        stagedMetadata[protectedContainer.appendingPathComponent(hidden).path] = metadata
        expect(folderLabel(url: protectedContainer) == expected, "Read metadata before releasing access")
        expect(activePaths.isEmpty && releasedHandles == 1, "Metadata access must be released after reading")

        let unknown = try container("unidentified")
        try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": ""], format: .xml, options: 0)
            .write(to: unknown.appendingPathComponent(hidden))
        expect(folderLabel(url: unknown) == nil, "Unidentified containers must remain unmatched")

        print("Passed 7 container metadata regression cases")
    }
}
