internal import CPrivateSPI
import CoreGraphics
import Dispatch
import Foundation

/// A live virtual screen. It exists for as long as this value, or a copy, is held, so whoever
/// owns it keeps it. Dropping the last copy destroys the screen.
///
/// Nothing in this type has a mutation guard, so the call site must check first.
/// `Scripts/lint.sh` confines callers to `LiveVirtualScreenProvider`.
public struct VirtualDisplayHandle {
    private let display: CGVirtualDisplay

    /// What the virtual screen calls need, so a change in a macOS update shows up in the probe
    /// and not as an unrecognized selector crash when a session starts.
    private static let requiredMembers: [(objcClass: String, selectors: [String])] = [
        ("CGVirtualDisplayMode", ["initWithWidth:height:refreshRate:"]),
        ("CGVirtualDisplaySettings", ["setModes:", "setHiDPI:"]),
        (
            "CGVirtualDisplayDescriptor",
            [
                "setName:", "setVendorID:", "setProductID:", "setSerialNum:",
                "setMaxPixelsWide:", "setMaxPixelsHigh:", "setSizeInMillimeters:",
                "setRedPrimary:", "setGreenPrimary:", "setBluePrimary:", "setWhitePoint:",
                "setTerminationHandler:", "setDispatchQueue:",
            ]
        ),
        ("CGVirtualDisplay", ["displayID", "initWithDescriptor:", "applySettings:"]),
    ]

    static var missingSymbols: [String] {
        requiredMembers.flatMap { member -> [String] in
            guard let objcClass = SymbolResolver.objcClass(member.objcClass) else { return [member.objcClass] }
            return member.selectors
                .filter { !SymbolResolver.hasInstanceMethod($0, on: objcClass) }
                .map { "\(member.objcClass).\($0)" }
        }
    }

    /// The screen's display ID, valid while this handle lives.
    ///
    /// Signature: `-[CGVirtualDisplay displayID]`, as read by runtime introspection and used in the
    /// 2026-11-06 spike. `THIRD_PARTY_NOTICES.md` credits the original declaration. Verified on
    /// macOS 27.0.1.
    ///
    /// Failure: there is no failure value. A handle only exists once `create` has passed the probe,
    /// which checks that this method is there.
    public var displayID: UInt32 { display.displayID }

    /// Creates a virtual screen. This changes real display state. Call `apply` next to give it
    /// its modes. The color primaries are the spec's fixed values.
    ///
    /// Signature: `CGVirtualDisplayDescriptor` and `-[CGVirtualDisplay initWithDescriptor:]`, as
    /// read by runtime introspection and used in the 2026-11-06 spike. `THIRD_PARTY_NOTICES.md`
    /// credits the original declarations. Verified on macOS 27.0.1.
    ///
    /// Failure: returns nil, without touching the classes, if the probe finds any of them missing
    /// or a max size doesn't fit in 32 bits, and also if the system declines to make the screen.
    ///
    /// - Parameter onTerminate: Runs on `queue` if the system ends the screen. The block's shape
    ///   comes from Apple's disassembly (see the header). No live screen has reached this path yet.
    public static func create(
        name: String,
        vendorID: UInt32,
        productID: UInt32,
        serial: UInt32,
        maxPixelsWide: Int,
        maxPixelsHigh: Int,
        sizeMM: (w: Double, h: Double),
        queue: DispatchQueue,
        onTerminate: @escaping @Sendable () -> Void
    ) -> VirtualDisplayHandle? {
        guard
            missingSymbols.isEmpty,
            let maxWide = UInt32(exactly: maxPixelsWide),
            let maxHigh = UInt32(exactly: maxPixelsHigh)
        else { return nil }

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(queue)
        descriptor.name = name
        descriptor.vendorID = vendorID
        descriptor.productID = productID
        descriptor.serialNum = serial
        descriptor.maxPixelsWide = maxWide
        descriptor.maxPixelsHigh = maxHigh
        descriptor.sizeInMillimeters = CGSize(width: sizeMM.w, height: sizeMM.h)
        descriptor.redPrimary = CGPoint(x: 0.68, y: 0.32)
        descriptor.greenPrimary = CGPoint(x: 0.265, y: 0.69)
        descriptor.bluePrimary = CGPoint(x: 0.15, y: 0.06)
        descriptor.whitePoint = CGPoint(x: 0.3127, y: 0.329)
        descriptor.terminationHandler = { _ in onTerminate() }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }
        return VirtualDisplayHandle(display: display)
    }

    /// Sets the screen's modes, in place, within the max size given to `create`. Each mode is a
    /// size in points. With `hiDPI` on, it is backed by 2Wx2H pixels. With it off, the spec expects
    /// WxH pixels, but the spike only tested HiDPI, so 1x is unverified and on the attended list.
    ///
    /// Signature: `CGVirtualDisplaySettings` and `-[CGVirtualDisplay applySettings:]`, which Swift
    /// imports as `apply(_:)`, as read by runtime introspection and used in the 2026-11-06 spike.
    /// `THIRD_PARTY_NOTICES.md` credits the original declarations. Verified on macOS 27.0.1, with
    /// `hiDPI` on only.
    ///
    /// Failure: returns false, without calling the system, if `modes` is empty or a mode can't be
    /// built, and otherwise returns what the system answers.
    public func apply(modes: [(w: Int, h: Int, hz: Double)], hiDPI: Bool) -> Bool {
        guard !modes.isEmpty else { return false }
        var declared: [CGVirtualDisplayMode] = []
        for mode in modes {
            guard
                let width = UInt32(exactly: mode.w),
                let height = UInt32(exactly: mode.h),
                let built = CGVirtualDisplayMode(width: width, height: height, refreshRate: mode.hz)
            else { return false }
            declared.append(built)
        }
        let settings = CGVirtualDisplaySettings()
        settings.modes = declared
        settings.hiDPI = hiDPI ? 1 : 0
        return display.apply(settings)
    }
}
