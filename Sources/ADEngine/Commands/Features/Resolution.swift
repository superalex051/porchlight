import ADDisplayConfig
import ADModel

/// `-resolution`, `-refreshRate` and `-hiDPI` of one `set`. They go as one change, because going through
/// them one at a time could pass through a mode the display doesn't offer.
struct ModeRequest {
    var resolution: ScreenSize?
    var refreshHz: Int?
    var hiDPI: Bool?

    var isEmpty: Bool { resolution == nil && refreshHz == nil && hiDPI == nil }

    func apply(to definition: inout VirtualScreenDefinition) throws {
        if let resolution {
            guard !definition.useResolutionList || definition.resolutionList.contains(resolution) else {
                throw CommandRefusal(reason: "\(resolution) is not in the screen's resolution list")
            }
            definition.looksLike = resolution
        }
        if let refreshHz { definition.hz = refreshHz }
        if let hiDPI { definition.hiDPI = hiDPI }
    }
}

extension CommandDispatcher {
    /// In points.
    func resolutionValue(of device: SelectedDevice) -> String? {
        device.mode.map { "\($0.pointsWide)x\($0.pointsHigh)" }
    }

    /// A screen made with `create` has one mode, so it changes by way of its definition.
    func setMode(_ request: ModeRequest, on devices: [SelectedDevice]) async throws {
        for device in devices {
            if let definition = device.definition {
                try await changeScreen(definition) { try request.apply(to: &$0) }
            } else if let id = device.id, device.isOnline {
                try await operations.selectMode(
                    id,
                    resolution: request.resolution,
                    refreshHz: request.refreshHz,
                    hiDPI: request.hiDPI
                )
            } else {
                throw DisplayOperationError.notOnline(device.id ?? 0)
            }
        }
    }
}
