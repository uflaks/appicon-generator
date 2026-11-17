import SwiftUI

/// The rounded-square outline the system gives icons, scaled to whatever rectangle it fills.
struct IconMask: InsettableShape {
    private var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: inset, dy: inset)
        // 185.4 / 824, the corner radius of Apple's icon grid relative to the tile's side.
        return RoundedRectangle(cornerRadius: min(rect.width, rect.height) * 0.225, style: .continuous)
            .path(in: rect)
    }

    func inset(by amount: CGFloat) -> IconMask {
        var shape = self
        shape.inset += amount
        return shape
    }
}

/// How artwork is presented: as delivered, or as it will look once the platform has shaped it.
enum PreviewShape: String, CaseIterable, Identifiable {
    case artwork = "Artwork"
    case iOS = "iOS"
    case macOS = "macOS"

    var id: Self { self }
}

struct IconPreview: View {
    let image: CGImage
    var shape = PreviewShape.iOS

    var body: some View {
        let artwork = Image(decorative: image, scale: 1)
            .resizable()
            .interpolation(.high)
            .aspectRatio(1, contentMode: .fit)

        switch shape {
        case .artwork:
            artwork
                .overlay(Rectangle().strokeBorder(.separator))
        case .iOS:
            artwork
                .clipShape(IconMask())
        case .macOS:
            // The tile covers 824 of the 1024 px canvas, with a soft shadow beneath it.
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                artwork
                    .clipShape(IconMask())
                    .shadow(color: .black.opacity(0.35), radius: side * 0.02, y: side * 0.012)
                    .frame(width: side * 824 / 1024, height: side * 824 / 1024)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }
}
