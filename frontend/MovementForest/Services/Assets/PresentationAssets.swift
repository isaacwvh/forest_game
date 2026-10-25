import Foundation
import UIKit
import ImageIO

enum PresentationAssets {
    static func url(_ path: String, bundle: Bundle = .main) -> URL? {
        guard !path.hasPrefix("/"), !path.contains("\\"), !path.split(separator: "/").contains(".."),
              let root = bundle.resourceURL else { return nil }
        let url = root.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Decode only display-sized pixels; avoid retaining full PNG canvases.
    static func image(_ path: String, maximumPixels: Int = 900) -> UIImage? {
        guard let url = url(path), let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    static func packPath(packID: String, part: String) -> String? {
        guard packID == "woodland", ["sealed", "opened", "top-strip"].contains(part) else { return nil }
        return "packs/woodland/v1/woodland-pack-\(part).png"
    }
}

struct VisitorAssetManifest: Decodable {
    let schemaVersion: Int
    let assetType: String
    let visitorId: String
    let units: String
    let authoringUpAxis: String
    let assets: [Asset]
    struct Asset: Decodable {
        let file: String
        let bounds: AssetBounds
        let bytes: Int
        let sha256: String
    }
    static func load() throws -> (Self, URL) {
        guard let manifestURL = PresentationAssets.url("butterfly/v1/butterfly.json") else {
            throw ForestError.missingResource("butterfly manifest")
        }
        let manifest = try JSONDecoder().decode(Self.self, from: Data(contentsOf: manifestURL))
        guard manifest.schemaVersion == 1, manifest.assetType == "visitor", manifest.visitorId == "butterfly",
              manifest.units == "metres", manifest.authoringUpAxis == "Z", manifest.assets.count == 1,
              let asset = manifest.assets.first, asset.bytes > 0, asset.sha256.count == 64,
              asset.bounds.min.count == 3, asset.bounds.max.count == 3,
              let model = PresentationAssets.url("butterfly/v1/" + asset.file) else {
            throw ForestError.invalidData("Invalid butterfly package.")
        }
        return (manifest, model)
    }
}
