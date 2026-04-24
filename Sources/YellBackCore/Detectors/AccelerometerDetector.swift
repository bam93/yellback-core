import Foundation
import IOKit
import IOKit.hid

/// Accelerometer-based desk-bang detector. Conforms to `Detector` (see
/// `Detector.swift` for the full contract).
///
/// ## Hardware path (Apple Silicon only)
///
/// `CMMotionManager` is `API_UNAVAILABLE(macos)`. Instead, this detector
/// reads the built-in Bosch BMI286 MEMS accelerometer via `IOHIDManager`,
/// matching on Apple's vendor-defined usage page `0xFF00`, usage `0x03`
/// (accelerometer). The sensor is exposed as `AppleSPUHIDDevice` through
/// the Sensor Processing Unit on M1 Pro/Max/Ultra and all M2/M3/M4 Macs.
/// Base M1 laptops and all Mac desktops (mini, Studio, Pro) have no
/// accessible accelerometer — `start()` throws `.hardwareUnavailable`.
///
/// ## Privileges
///
/// `IOHIDManagerOpen` returns `kIOReturnNotPrivileged` unless the process
/// is running as root. The CLI requires `sudo yellback --listen`; the paid
/// Mac app will ship a privileged helper via `SMAppService.daemon`. There
/// is no user-grantable entitlement — this is an undocumented API.
/// `start()` surfaces the privilege gap as `DetectorError.needsPrivilegedAccess`
/// so consumers can show actionable messaging instead of a silent no-op.
///
/// ## Report format
///
/// Each HID input report is 22 bytes (the driver's native layout):
///
///   - bytes 0-5: metadata (report ID, timestamp, frame counter)
///   - bytes 6-9: X axis as int32 little-endian, Q16.16 fixed-point g-force
///   - bytes 10-13: Y axis, same format
///   - bytes 14-17: Z axis, same format
///   - bytes 18-21: trailing padding
///
/// Parsing is isolated in `parseReport(_:length:)` so tests can feed
/// synthetic 22-byte buffers without any IOKit involvement.
///
/// ## Threading
///
/// The HID manager is scheduled on the main run loop; callbacks fire on
/// the main thread. `process(sample:)` is the testable core and is called
/// from tests directly and from the HID callback at runtime.
///
/// ## Privacy invariant
///
/// Retains no motion samples between calls. Only the current-reading
/// intensity is emitted; no buffer of past samples is kept.
public final class AccelerometerDetector: Detector {

    // MARK: - Detector conformance

    public let trigger: Trigger = .deskBang

    public var isEnabled: Bool

    public var onTriggerEvent: ((TriggerEvent) -> Void)?
    public var onIntensitySignal: ((IntensitySignal) -> Void)?

    // MARK: - Captured config

    private let config: DeskBangConfig

    // MARK: - State

    /// Engine-settable priming multiplier, parallel to `MicDetector`'s. Set
    /// by the engine when its `PrimingState` transitions. Default `1.0`
    /// (no priming). See `MicDetector.primingMultiplier` for rationale —
    /// semantics identical here except the threshold is in g-force units,
    /// so no log conversion is needed.
    public var primingMultiplier: Double = 1.0

    // MARK: - IOKit state

    private var hidManager: IOHIDManager?

    /// Stable box to hand IOKit as the `context` pointer so the C callback
    /// can reach back to `self` without unsafe self-casts.
    private var callbackContext: UnsafeMutableRawPointer?

    // MARK: - Init

    public init(config: DeskBangConfig) {
        self.config = config
        self.isEnabled = config.enabled
    }

    deinit {
        stop()
    }

    // MARK: - Detector lifecycle

    public func start() throws {
        stop()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.appleVendorID,
            kIOHIDPrimaryUsagePageKey as String: Self.appleSensorUsagePage,
            kIOHIDPrimaryUsageKey as String: Self.accelerometerUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        switch openResult {
        case kIOReturnSuccess:
            break
        case kIOReturnNotPrivileged:
            throw DetectorError.needsPrivilegedAccess(
                trigger: .deskBang,
                reason: "IOHIDManagerOpen returned kIOReturnNotPrivileged — run as root (sudo) or via a privileged helper"
            )
        default:
            throw DetectorError.inputSetupFailed(
                trigger: .deskBang,
                underlying: "IOHIDManagerOpen returned IOReturn 0x\(String(openResult, radix: 16))"
            )
        }

        // Verify a matching device is actually present. If the matching-set
        // is empty after open, there's no accelerometer on this Mac.
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        guard !devices.isEmpty else {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            throw DetectorError.hardwareUnavailable(
                trigger: .deskBang,
                reason: "no AppleSPUHIDDevice accelerometer found (expected on base M1, Mac mini, Mac Studio, Mac Pro)"
            )
        }

        // Hand IOKit a stable context pointer to a heap box holding `self`
        // so the C callback can reach back without capturing Swift closure
        // state (IOKit callbacks aren't Swift closures — they're C function
        // pointers).
        let box = Unmanaged.passRetained(CallbackBox(owner: self))
        let context = UnsafeMutableRawPointer(box.toOpaque())
        self.callbackContext = context

        IOHIDManagerRegisterInputReportCallback(
            manager,
            Self.inputReportCallback,
            context
        )

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.hidManager = manager
    }

    public func stop() {
        if let manager = hidManager {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        hidManager = nil
        if let ctx = callbackContext {
            Unmanaged<CallbackBox>.fromOpaque(ctx).release()
        }
        callbackContext = nil
    }

    // MARK: - Process (testable core)

    /// Primary detection entry point. Called from the HID callback at
    /// runtime, or directly from tests with synthesised samples.
    func process(sample: AccelerometerSample) {
        guard isEnabled else { return }

        // The accelerometer at rest reads magnitude ~1g (gravity). Detect
        // impulses via the *delta* from 1g, not absolute magnitude.
        let magnitude = sqrt(sample.x * sample.x + sample.y * sample.y + sample.z * sample.z)
        let gForceDelta = abs(magnitude - 1.0)

        let now = Date()
        let intensity = normalizedIntensity(fromGForceDelta: gForceDelta)
        onIntensitySignal?(IntensitySignal(value: intensity, timestamp: now))

        let effectiveThreshold = effectiveThresholdGForce()
        guard gForceDelta >= effectiveThreshold else { return }

        // wasPrimed: true iff priming was the proximate cause. Same
        // semantics as MicDetector.
        let wasPrimed = gForceDelta < config.gForceThreshold && gForceDelta >= effectiveThreshold

        onTriggerEvent?(TriggerEvent(
            trigger: .deskBang,
            timestamp: now,
            intensity: intensity,
            wasPrimed: wasPrimed
        ))
    }

    // MARK: - Helpers

    private func effectiveThresholdGForce() -> Double {
        guard primingMultiplier > 0 else { return config.gForceThreshold }
        return config.gForceThreshold * primingMultiplier
    }

    /// Map g-force delta to 0..1 intensity. 0g delta → 0 (at rest).
    /// 3g delta → 1 (saturating — firm slams are the upper sensory range).
    private func normalizedIntensity(fromGForceDelta delta: Double) -> Double {
        let clipped = max(0.0, min(3.0, delta))
        return clipped / 3.0
    }

    // MARK: - Report parsing (testable, pure)

    /// Parse a 22-byte HID input report into an `AccelerometerSample`.
    /// Returns nil if the report is shorter than expected — callers should
    /// ignore undersized reports rather than treat them as zero-g.
    ///
    /// Report layout (observed via ioreg + reverse-engineered by
    /// `olvvier/apple-silicon-accelerometer`):
    ///
    ///   - bytes 6-9:   X, int32 LE, Q16.16 fixed-point g-force
    ///   - bytes 10-13: Y, same
    ///   - bytes 14-17: Z, same
    ///
    /// Pure function — no IOKit involvement, fully testable by feeding
    /// synthetic `UInt8` arrays.
    static func parseReport(_ bytes: UnsafePointer<UInt8>, length: Int, at timestamp: TimeInterval = 0) -> AccelerometerSample? {
        guard length >= 18 else { return nil }
        let raw = UnsafeRawPointer(bytes)
        // `loadUnaligned` is required: offsets 6/10/14 aren't 4-byte-aligned
        // and `load(fromByteOffset:as:)` traps on unaligned reads.
        let x = raw.loadUnaligned(fromByteOffset: 6, as: Int32.self).littleEndian
        let y = raw.loadUnaligned(fromByteOffset: 10, as: Int32.self).littleEndian
        let z = raw.loadUnaligned(fromByteOffset: 14, as: Int32.self).littleEndian
        let scale = 1.0 / 65536.0
        return AccelerometerSample(
            x: Double(x) * scale,
            y: Double(y) * scale,
            z: Double(z) * scale,
            timestamp: timestamp
        )
    }

    // MARK: - IOKit vendor/usage constants

    private static let appleVendorID: Int = 0x05AC
    private static let appleSensorUsagePage: Int = 0xFF00
    private static let accelerometerUsage: Int = 0x03

    // MARK: - C callback bridge

    /// IOKit input-report callback. Parses the raw report and forwards the
    /// sample to the detector's `process(sample:)`. Receives the detector
    /// instance via the `context` pointer set up in `start()`.
    private static let inputReportCallback: IOHIDReportCallback = { context, _, _, _, _, report, length in
        guard let context = context else { return }
        let owner = Unmanaged<CallbackBox>.fromOpaque(context).takeUnretainedValue().owner
        guard let sample = AccelerometerDetector.parseReport(report, length: length) else { return }
        owner?.process(sample: sample)
    }
}

// MARK: - Sample value type

/// Single accelerometer reading. Units are g-force (1g ≈ 9.81 m/s²);
/// at rest the magnitude is ~1 due to gravity.
struct AccelerometerSample {
    let x: Double
    let y: Double
    let z: Double
    let timestamp: TimeInterval
}

/// Retained heap box so IOKit's C callback can find the detector via a
/// stable opaque pointer. `weak` reference avoids a retain cycle — if the
/// detector is deallocated while a report is in flight, the callback
/// no-ops.
private final class CallbackBox {
    weak var owner: AccelerometerDetector?
    init(owner: AccelerometerDetector) { self.owner = owner }
}
