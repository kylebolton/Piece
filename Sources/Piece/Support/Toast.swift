import SwiftUI
import MacToastKit

/// Thin wrapper over MacToastKit. A fresh controller is used per toast because
/// the library reuses its panel (and first message) for a controller's lifetime;
/// the panel retains itself until its fade-out finishes.
@MainActor
enum Toast {
    static func show(_ message: String, systemImage: String = "checkmark.circle.fill", duration: TimeInterval = 3) {
        ToastWindowController().showToast(
            message: message,
            icon: Image(systemName: systemImage),
            duration: duration,
            position: .bottomCenter(100)
        )
    }
}
