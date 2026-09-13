import Foundation

/// Bluetooth identifiers observed on the Limitless Pendant.
///
/// Kept as strings so the protocol module remains testable without constructing
/// CoreBluetooth objects. The app's transport converts these to `CBUUID`.
public enum PendantUUIDs {
    public static let audioService = "632DE001-604C-446B-A80F-7963E950F3FB"
    public static let control = "632DE002-604C-446B-A80F-7963E950F3FB"
    public static let data = "632DE003-604C-446B-A80F-7963E950F3FB"
    public static let batteryService = "180F"
    public static let batteryLevel = "2A19"
}
