import SwiftUI
import VisionKit

/// Native QR scanner for the WebRTC remote-ID field, replacing Compose's
/// `easyqrscan`-backed `QrScanDialog`. `DataScannerViewController` (VisionKit, iOS 16+) needs
/// no third-party dependency and far less code than raw `AVCaptureMetadataOutput`.
///
/// Payload handling mirrors `WebRTCConnectionContent.onScanned` in `SettingsScreen.kt`: strip
/// the `WEB_RTC_URL_PREFIX` if the scanned text starts with the app's share-link URL, else use
/// the raw text. Deliberately **fixed** here, not byte-for-byte ported: Compose's version
/// computes `scannedText.indexOf(prefix) + prefix.length` and only falls back to the raw text
/// when that offset is `>= scannedText.length` — if the prefix is simply absent, `indexOf`
/// returns `-1`, so a scanned string of the right length gets sliced from a garbage offset
/// instead of falling back. This is pure UI parsing logic with no protocol risk, so the bug
/// isn't reproduced.
struct QrScanView: View {

    let onScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private static let webRtcUrlPrefix = "https://app.music-assistant.io/?remote_id="

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    ScannerRepresentable { text in
                        onScanned(Self.extractRemoteId(from: text))
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        String(localized: "settings_scan_qr"),
                        systemImage: "qrcode.viewfinder",
                        description: Text(String(localized: "settings_qr_scan_unavailable"))
                    )
                }
            }
            .navigationTitle(String(localized: "settings_scan_qr"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "common_cancel")) { dismiss() }
                }
            }
        }
    }

    private static func extractRemoteId(from scannedText: String) -> String {
        guard let range = scannedText.range(of: webRtcUrlPrefix) else { return scannedText }
        return String(scannedText[range.upperBound...])
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    let onScanned: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScanned: onScanned) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onScanned: (String) -> Void
        private var didFire = false

        init(onScanned: @escaping (String) -> Void) {
            self.onScanned = onScanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !didFire, case let .barcode(barcode) = addedItems.first, let value = barcode.payloadStringValue else { return }
            didFire = true
            onScanned(value)
        }
    }
}
