import CoreGraphics
import Foundation
import Testing

@testable import ADSPI

// Everything here reads only. These tests must never make a virtual display or
// start a display configuration, because this Mac is in live use.

private let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

@Test func probeFindsEverySymbolOnThisMac() {
    let capabilities = SPICapabilities.probe()
    #expect(capabilities.missing == [])
    #expect(capabilities.displayList)
    #expect(capabilities.infoDictionary)
    #expect(capabilities.enableDisable)
    #expect(capabilities.virtualDisplay)
}

@Test func allDisplayIDsIsNonEmpty() {
    #expect(SkyLight.allDisplayIDs()?.isEmpty == false)
}

@Test func infoDictionaryOfMainDisplayIsReadable() {
    let info = CoreDisplayInfo.info(for: CGMainDisplayID())
    #expect(!info.isEmpty)
    // The flag is always there, so this fails if the keys ever stop matching the dictionary.
    #expect(info["kCGDisplayIsVirtualDevice"] is Bool)
    if !CoreDisplayInfo.isVirtual(info) {
        #expect(CoreDisplayInfo.registryLocation(info) != nil)
    }
}

@Test func resolverTriesTheNextPathWhenOneDoesNotLoad() {
    #expect(SymbolResolver.symbol("SLSGetDisplayList", in: ["/nonexistent/Framework", skyLightPath]) != nil)
}

@Test func resolverReportsWhatIsNotThere() {
    #expect(SymbolResolver.symbol("ADNoSuchSymbol", in: [skyLightPath]) == nil)
    #expect(!SymbolResolver.isLoaded("ADNoSuchSymbol"))
    #expect(SymbolResolver.objcClass("ADNoSuchClass") == nil)
    #expect(!SymbolResolver.hasInstanceMethod("adNoSuchSelector", on: NSObject.self))
}

@Test func resolverFindsWhatIsThere() {
    #expect(SymbolResolver.isLoaded("CGMainDisplayID"))
    #expect(SymbolResolver.objcClass("NSObject") != nil)
    #expect(SymbolResolver.hasInstanceMethod("description", on: NSObject.self))
}

@Test func reportNamesMissingSymbols() {
    let capabilities = SPICapabilities(
        displayList: true,
        infoDictionary: true,
        enableDisable: false,
        virtualDisplay: true,
        missing: ["X"]
    )
    #expect(capabilities.report.contains("X"))
    #expect(capabilities.report.contains("enableDisable"))
    #expect(!capabilities.report.contains("displayList"))
}

@Test func reportSaysSoWhenNothingIsMissing() {
    let capabilities = SPICapabilities(
        displayList: true,
        infoDictionary: true,
        enableDisable: true,
        virtualDisplay: true,
        missing: []
    )
    #expect(capabilities.report == "All private display symbols resolved.")
}

@Test func accessorsReadTheInfoDictionaryKeys() {
    let info: [String: Any] = [
        "IODisplayLocation": "IOService:/AppleARMPE/dispext0",
        "kCGDisplayIsVirtualDevice": true,
        "DisplayProductName": ["ro_RO": "Monitor RO", "en_US": "Monitor US"],
    ]
    #expect(CoreDisplayInfo.registryLocation(info) == "IOService:/AppleARMPE/dispext0")
    #expect(CoreDisplayInfo.isVirtual(info))
    #expect(CoreDisplayInfo.productName(info) == "Monitor US")
}

@Test func productNameWithoutEnglishIsStable() {
    let info: [String: Any] = ["DisplayProductName": ["ro_RO": "Monitor RO", "de_DE": "Monitor DE"]]
    #expect(CoreDisplayInfo.productName(info) == "Monitor DE")
}

@Test func productNameOfAnEmptyPipeIsNil() {
    let info: [String: Any] = ["DisplayProductName": ["ar": "", "en_US": ""]]
    #expect(CoreDisplayInfo.productName(info) == nil)
}

@Test func accessorsTolerateAnEmptyDictionary() {
    #expect(CoreDisplayInfo.registryLocation([:]) == nil)
    #expect(!CoreDisplayInfo.isVirtual([:]))
    #expect(CoreDisplayInfo.productName([:]) == nil)
}
