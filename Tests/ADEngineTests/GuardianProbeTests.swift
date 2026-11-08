import ADIPC
import ADModel
import Foundation
import Testing

@testable import ADEngine

private func socketPath() -> String {
    let name = UUID().uuidString.prefix(8)
    return URL(fileURLWithPath: NSTemporaryDirectory()).appending(component: "adp-\(name).sock").path
}

@Test func probeSeesAnAnsweringGuardian() async throws {
    let path = socketPath()
    let seen = Recorder<CommandRequest>()
    let server = IPCServer(path: path) { request in
        seen.append(request)
        return .success("pong")
    }
    try server.start()
    server.setReady(true)
    defer { server.stop() }

    #expect(await IPCGuardianProbe(socketPath: path).isAlive())
    #expect(seen.values == [CommandRequest(operations: ["ping"], parameters: [])])
}

@Test func probeTakesABusyGuardianAsUp() async throws {
    let path = socketPath()
    let server = IPCServer(path: path) { _ in .success("pong") }
    try server.start()
    defer { server.stop() }

    #expect(await IPCGuardianProbe(socketPath: path).isAlive())
}

@Test func probeTakesAThrownErrorAsDown() async {
    #expect(await !IPCGuardianProbe(socketPath: socketPath()).isAlive())
}

@Test func probeTakesAnyOtherFailureAsDown() async throws {
    let path = socketPath()
    let server = IPCServer(path: path) { _ in .failure("no") }
    try server.start()
    server.setReady(true)
    defer { server.stop() }

    #expect(await !IPCGuardianProbe(socketPath: path).isAlive())
}

@Test func probeGivesUpOnASilentGuardianAfterOneSecond() async throws {
    let path = socketPath()
    let server = IPCServer(path: path) { _ in
        try? await Task.sleep(for: .seconds(5))
        return .success("pong")
    }
    try server.start()
    server.setReady(true)
    defer { server.stop() }

    let start = Date()
    #expect(await !IPCGuardianProbe(socketPath: path).isAlive())
    #expect(Date().timeIntervalSince(start) < 3)
}

@Test func fakeProbeSaysWhatItIsTold() async {
    #expect(await FakeGuardianProbe().isAlive())
    #expect(await !FakeGuardianProbe(alive: false).isAlive())
}
