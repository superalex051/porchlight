import ADModel
import CoreGraphics
import Foundation

/// A size, in points for `looksLike` and in pixels for `pixels`.
public struct PorchLightSize: Sendable, Equatable, Hashable, Codable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    private enum CodingKeys: String, CodingKey {
        case width = "w"
        case height = "h"
    }
}

/// The session status object of API version 1, as every session command returns it. Section 3 of
/// `docs/session-api.md` says what each value means. With no session only `state`
/// and `apiVersion` are set.
public struct PorchLightStatus: Sendable, Equatable {
    public enum State: String, Sendable, Equatable, Decodable {
        /// No session.
        case idle
        /// A start is running.
        case starting
        /// The screen is up and main, and the monitors are off.
        case active
        /// The app stopped putting things back after too many changes. The session still works.
        case degraded
        /// An end is running, or the last one failed.
        case ending
    }

    public var apiVersion: Int
    public var state: State
    public var client: String?
    /// The virtual screen to capture. It changes whenever the screen is made again, so always take it
    /// from the latest status. Nil while the screen isn't online.
    public var displayID: CGDirectDisplayID?
    /// The same for a given client name across sessions and relaunches. Nil whenever `displayID` is.
    public var displayUUID: String?
    public var looksLike: PorchLightSize?
    public var pixels: PorchLightSize?
    public var hiDPI: Bool?
    public var hz: Int?
    public var ownerPIDs: [Int32]
    /// The monitors this session turned off that are still off.
    public var physicalOff: [CGDirectDisplayID]

    /// For a caller's own tests. Porch Light's answers are read by `PorchLightClient`.
    public init(
        apiVersion: Int = PorchLightClient.apiVersion,
        state: State,
        client: String? = nil,
        displayID: CGDirectDisplayID? = nil,
        displayUUID: String? = nil,
        looksLike: PorchLightSize? = nil,
        pixels: PorchLightSize? = nil,
        hiDPI: Bool? = nil,
        hz: Int? = nil,
        ownerPIDs: [Int32] = [],
        physicalOff: [CGDirectDisplayID] = []
    ) {
        self.apiVersion = apiVersion
        self.state = state
        self.client = client
        self.displayID = displayID
        self.displayUUID = displayUUID
        self.looksLike = looksLike
        self.pixels = pixels
        self.hiDPI = hiDPI
        self.hz = hz
        self.ownerPIDs = ownerPIDs
        self.physicalOff = physicalOff
    }

    /// Reads the status object from an answer. Anything that isn't version 1's object is refused, so a
    /// newer Porch Light can't be misread.
    init(json: JSONValue) throws(PorchLightClientError) {
        guard case .object(let fields) = json else {
            throw .unsupportedReply("the status isn't a JSON object")
        }
        let version: Int?
        if case .number(let number)? = fields["apiVersion"] { version = Int(exactly: number) } else { version = nil }
        guard version == PorchLightClient.apiVersion else {
            let found = version.map(String.init) ?? "missing"
            throw .unsupportedReply("API version \(found); this library speaks \(PorchLightClient.apiVersion)")
        }
        do {
            self = try JSONDecoder().decode(Wire.self, from: JSONEncoder().encode(json)).status
        } catch {
            throw .unsupportedReply("the status could not be read: \(error)")
        }
    }

    /// The object as it's written. With no session the arrays aren't there.
    private struct Wire: Decodable {
        var apiVersion: Int
        var state: State
        var client: String?
        var displayID: CGDirectDisplayID?
        var displayUUID: String?
        var looksLike: PorchLightSize?
        var pixels: PorchLightSize?
        var hiDPI: Bool?
        var hz: Int?
        var ownerPIDs: [Int32]?
        var physicalOff: [CGDirectDisplayID]?

        var status: PorchLightStatus {
            PorchLightStatus(
                apiVersion: apiVersion,
                state: state,
                client: client,
                displayID: displayID,
                displayUUID: displayUUID,
                looksLike: looksLike,
                pixels: pixels,
                hiDPI: hiDPI,
                hz: hz,
                ownerPIDs: ownerPIDs ?? [],
                physicalOff: physicalOff ?? []
            )
        }
    }
}
