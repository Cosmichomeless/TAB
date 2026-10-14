import CoreImage.CIFilterBuiltins
import SwiftUI

/// Draws a QR code on the device. Nothing is sent anywhere: the code simply carries the group link.
enum QRCode {
    /// Bytes a medium-correction QR code can hold, minus some margin so it stays easy to scan.
    static let capacity = 2_000

    static func image(for text: String) -> UIImage? {
        guard text.utf8.count <= capacity else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Integer scaling keeps the modules crisp.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
