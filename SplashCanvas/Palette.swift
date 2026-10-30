import SwiftUI

enum PaletteItem: Hashable {
    case paint(Int)
    case rainbow
    case style
}

enum Palette {
    static let paints: [SIMD3<Float>] = [
        SIMD3(0.97, 0.22, 0.30), // coral
        SIMD3(1.00, 0.55, 0.08), // tangerine
        SIMD3(1.00, 0.82, 0.12), // sunflower
        SIMD3(0.10, 0.78, 0.55), // mint
        SIMD3(0.08, 0.48, 0.96), // ocean
        SIMD3(0.56, 0.28, 0.95), // violet
    ]

    static let items: [PaletteItem] = paints.indices.map { PaletteItem.paint($0) } + [.rainbow, .style]

    static func color(_ rgb: SIMD3<Float>) -> Color {
        Color(red: Double(rgb.x), green: Double(rgb.y), blue: Double(rgb.z))
    }
}
