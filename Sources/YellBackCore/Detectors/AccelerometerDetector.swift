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

    /// Devices we've installed per-device input-report callbacks on. Tracked
    /// so we can unregister + close on stop().
    private var attachedDevices: [IOHIDDevice] = []

    /// Per-device report buffers. IOKit writes incoming reports here before
    /// invoking the callback; the buffer must outlive the registration.
    private var reportBuffers: [UnsafeMutablePointer<UInt8>] = []

    private static let reportBufferSize = 64

    /// When `true`, `start()` prints diagnostic information to stderr:
    /// the wake-count, matched-device list with their HID properties.
    /// CLI consumers should set this to `true` when running under
    /// `logging.level == .debug`. Default `false`.
    public var verboseDiagnostics: Bool = false

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

        // M2/M3/M4 SPU sensors ship in an idle state: PowerState=0,
        // ReportingState=0. Until the driver is "woken" by setting three
        // IORegistry properties, the HID device matches and opens cleanly
        // but never delivers reports. M1 / M1 Pro happen to be woken by
        // the OS's lid-angle service so this step was implicit. Newer
        // chips need it explicitly.
        Self.wakeSPUDriver(verbose: verboseDiagnostics)

        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let match: [String: Any] = [
            kIOHIDVendorIDKey as String: Self.appleVendorID,
            kIOHIDPrimaryUsagePageKey as String: Self.appleSensorUsagePage,
            kIOHIDPrimaryUsageKey as String: Self.accelerometerUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, match as CFDictionary)

        // Schedule the manager with the main run loop BEFORE opening. The
        // working reverse-engineered references (OpenSlap, olvvier) all
        // schedule first; opening before scheduling has been observed to
        // race the first reports out the window.
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        // Open WITHOUT seize. On M2/M3/M4, kIOHIDOptionsTypeSeizeDevice
        // evicts the other SPU consumers (e.g. lid-angle service) that
        // were keeping the sensor woken, and the report stream silently
        // dies. kIOHIDOptionsTypeNone keeps the sensor awake and lets us
        // co-receive reports.
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
        let devices = Array(IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? [])
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

        if verboseDiagnostics {
            Self.logMatchedDevices(devices)
        }

        // Per-device input-report callback registration. The 3-arg modern
        // `IOHIDManagerRegisterInputReportCallback` doesn't deliver for
        // AppleSPUHIDDevice; per-device registration with an explicit
        // buffer is what works. Do NOT call `IOHIDDeviceOpen` or
        // `IOHIDDeviceScheduleWithRunLoop` — the manager-level open and
        // schedule already cover the matched devices, and double-opening
        // has been seen to break the report stream on M3/M4.
        for device in devices {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.reportBufferSize)
            buffer.initialize(repeating: 0, count: Self.reportBufferSize)
            IOHIDDeviceRegisterInputReportCallback(
                device,
                buffer,
                CFIndex(Self.reportBufferSize),
                Self.inputReportCallback,
                context
            )
            attachedDevices.append(device)
            reportBuffers.append(buffer)
        }

        self.hidManager = manager
    }

    /// Wakes the AppleSPUHIDDriver IORegistry node so the sensor delivers
    /// HID input reports. On M2/M3/M4 the SPU sensor sits in an idle state
    /// (PowerState=0, ReportingState=0) until something explicitly bumps
    /// these properties. M1 / M1 Pro Macs happen to have a system service
    /// (lid-angle / orientation) that does this implicitly, which is why
    /// older devices "just worked" with kIOHIDOptionsTypeNone but newer
    /// ones don't.
    ///
    /// Properties set:
    ///   - SensorPropertyReportingState = 1  (start delivering reports)
    ///   - SensorPropertyPowerState     = 1  (power on the sensor)
    ///   - ReportInterval               = 1000 microseconds (1 kHz)
    ///
    /// Idempotent — calling repeatedly is harmless.
    private static func wakeSPUDriver(verbose: Bool) {
        guard let matching = IOServiceMatching("AppleSPUHIDDriver") else {
            if verbose {
                FileHandle.standardError.write(Data("[diag] IOServiceMatching(\"AppleSPUHIDDriver\") returned nil\n".utf8))
            }
            return
        }
        var iterator: io_iterator_t = 0
        let getResult = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard getResult == kIOReturnSuccess else {
            if verbose {
                FileHandle.standardError.write(Data(
                    "[diag] IOServiceGetMatchingServices returned 0x\(String(getResult, radix: 16))\n".utf8
                ))
            }
            return
        }
        defer { IOObjectRelease(iterator) }

        var wokenCount = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            let one = 1 as CFNumber
            let interval = 1000 as CFNumber  // microseconds → 1 kHz request
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, one)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState"     as CFString, one)
            IORegistryEntrySetCFProperty(service, "ReportInterval"               as CFString, interval)
            wokenCount += 1
        }

        if verbose {
            FileHandle.standardError.write(Data(
                "[diag] AppleSPUHIDDriver: woke \(wokenCount) IORegistry entrie(s)\n".utf8
            ))
        }
    }

    private static func logMatchedDevices(_ devices: [IOHIDDevice]) {
        let header = "[diag] AccelerometerDetector matched \(devices.count) HID device(s):\n"
        FileHandle.standardError.write(Data(header.utf8))
        for (i, device) in devices.enumerated() {
            let product = (IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String) ?? "?"
            let manufacturer = (IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String) ?? "?"
            let usagePage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? Int) ?? -1
            let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? Int) ?? -1
            let maxReport = (IOHIDDeviceGetProperty(device, kIOHIDMaxInputReportSizeKey as CFString) as? Int) ?? -1
            let line = String(
                format: "[diag]   [%d] product='%@' manufacturer='%@' usagePage=0x%X usage=0x%X maxInputReportSize=%d\n",
                i, product, manufacturer, usagePage, usage, maxReport
            )
            FileHandle.standardError.write(Data(line.utf8))
        }
    }

    public func stop() {
        // Per-device teardown: unregister callback by passing nil. We never
        // called IOHIDDeviceOpen / IOHIDDeviceScheduleWithRunLoop, so don't
        // call the matching teardowns either — the manager-level close
        // covers them.
        for (device, buffer) in zip(attachedDevices, reportBuffers) {
            IOHIDDeviceRegisterInputReportCallback(
                device,
                buffer,
                CFIndex(Self.reportBufferSize),
                nil,
                nil
            )
        }
        for buffer in reportBuffers {
            buffer.deinitialize(count: Self.reportBufferSize)
            buffer.deallocate()
        }
        attachedDevices = []
        reportBuffers = []

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
