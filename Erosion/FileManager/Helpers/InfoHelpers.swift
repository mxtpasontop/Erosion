//
//  FilosHelpers.swift
//  Filos
//
//  Created by lunginspector on 7/22/26.
//

import Foundation
import Darwin

enum FolderType {
    case normal, bundle, container
}

func getFolderType(url: URL) -> FolderType {
    let parent = url.deletingLastPathComponent().path
    
    if parent == FSPaths.appBundles {
        return .bundle
    } else if parent == FSPaths.appContainers {
        return .container
    }
    return .normal
}

func getBIDFromXattr(_ url: URL) -> String? {
    _ = wq.grantAccess(path: url.path)
    
    var buf = [UInt8](repeating: 0, count: 512)
    
    let len = buf.withUnsafeMutableBytes {
        getxattr(url.path, "com.apple.containermanager.identifier", $0.baseAddress, 511, 0, XATTR_NOFOLLOW)
    }
    if len < 0 {
        let error = errno
        // Some containers identify themselves only in their metadata plist.
        if error != ENOATTR {
            print("failed to read container xattr at \(url.path): \(String(cString: strerror(error))) (errno \(error))")
        }
        return nil
    }
    let bytes = buf.prefix(Int(len)).prefix { $0 != 0 }
    guard let bid = String(bytes: bytes, encoding: .utf8), !bid.isEmpty else { return nil }
    return bid
}

func folderLabel(url: URL) -> String? {
    if let id = getBIDFromXattr(url) {
        return id
    }

    let candidates = [
        url.appendingPathComponent(".com.apple.mobile_container_manager.metadata.plist"),
        url.appendingPathComponent("com.apple.mobile_container_manager.metadata.plist")
    ]

    for url in candidates {
        if let data = try? Data(contentsOf: url), let id = metadataID(from: data) {
            return id
        }
    }

    for url in candidates {
        if let id = readMetaKey(at: url, key: "MCMMetadataIdentifier"), !id.isEmpty {
            return id
        }
    }
    return nil
}

func metadataID(from data: Data) -> String? {
    let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    guard let id = plist?["MCMMetadataIdentifier"] as? String, !id.isEmpty else { return nil }
    return id
}

func readMetaKey(at url: URL, key: String) -> String? {
    let alternateFlags = url.path.contains("/var/mobile/Containers/Shared/AppGroup") && ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 26
    let handle = worse_query(url.path, group, alternateFlags, false)
    guard handle >= 0 else { return nil }
    defer { worse_query_release(handle) }
     
    guard let data = try? Data(contentsOf: url),
          let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        return nil
    }

    return plist[key] as? String
}

enum SysBID {
    static var phone = "com.apple.mobilephone"
    static var poster = "com.apple.PosterBoard"
}
