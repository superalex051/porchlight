import ADModel
import Foundation

extension CommandDispatcher {
    /// Pretty-printed objects joined by commas, with no array around them, so scripts written for that
    /// shape keep working. It isn't one JSON document, which `--json` fixes with `identifiersJSON`.
    func identifiersText(_ devices: [SelectedDevice]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return identifierObjects(devices)
            .compactMap { (try? encoder.encode($0)).map { String(decoding: $0, as: UTF8.self) } }
            .joined(separator: ",")
    }

    func identifiersJSON(_ devices: [SelectedDevice]) -> JSONValue {
        .array(identifierObjects(devices).map { .object($0.mapValues(JSONValue.string)) })
    }

    /// Every value is a string and every key is always there, empty if the display doesn't report it.
    private func identifierObjects(_ devices: [SelectedDevice]) -> [[String: String]] {
        devices.map { device in
            let identity = device.identity
            return [
                "UUID": identity.uuid ?? "",
                "alphanumericSerial": identity.alphanumericSerial ?? "",
                "deviceType": device.deviceType,
                "displayID": device.id.map(String.init) ?? "",
                "model": String(identity.model),
                "name": device.name,
                "originalName": device.name,
                "productName": device.name,
                "registryLocation": identity.registryLocation ?? "",
                "serial": String(identity.serial),
                "tagID": device.tagID.map(String.init) ?? "",
                "vendor": String(identity.vendor),
                "weekOfManufacture": identity.weekOfManufacture.map(String.init) ?? "",
                "yearOfManufacture": identity.yearOfManufacture.map(String.init) ?? "",
            ]
        }
    }
}
