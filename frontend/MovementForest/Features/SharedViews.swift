import SwiftUI

struct RecoveryView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "leaf").font(.largeTitle).foregroundStyle(Color.forestTint)
            Text(title).font(.title2).bold()
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button(actionTitle, action: action).buttonStyle(.borderedProminent)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlantThumbnail: View {
    let plant: GardenPlant
    let catalog: any AssetCatalogProviding
    var body: some View {
        Group {
            if let asset = try? catalog.resolve(plant), let image = UIImage(contentsOfFile: asset.thumbnailURL.path) {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "leaf").resizable().scaledToFit().padding()
            }
        }.accessibilityHidden(true)
    }
}

struct DetailRow: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }.padding(.vertical, 3).accessibilityElement(children: .combine)
    }
}
