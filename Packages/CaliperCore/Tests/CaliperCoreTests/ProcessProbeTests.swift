import Darwin
import Foundation
import Testing

@testable import CaliperCore

// MARK: - The family rule, without a filesystem

@Test func theOutermostAppBundleUnitesTheFamily() {
    // Chrome's helpers carry their own bundle ids; the path is what unites
    // them with the browser.
    let helper =
        "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework"
        + "/Versions/139/Helpers/Google Chrome Helper (Renderer).app"
        + "/Contents/MacOS/Google Chrome Helper (Renderer)"
    let browser = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    let helperBundle = ProcessFamilyKey.appBundleURL(forExecutablePath: helper)
    let browserBundle = ProcessFamilyKey.appBundleURL(forExecutablePath: browser)
    #expect(helperBundle == browserBundle)
    #expect(helperBundle?.path == "/Applications/Google Chrome.app")
}

@Test func aBarePathHasNoBundle() {
    #expect(ProcessFamilyKey.appBundleURL(forExecutablePath: "/usr/local/bin/node") == nil)
    #expect(ProcessFamilyKey.appBundleURL(forExecutablePath: "") == nil)
}

@Test func membershipFollowsTheKey() {
    let family = ProcessFamilyKey.bundle(
        identifier: "com.google.Chrome",
        appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
    )
    #expect(family.contains(executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"))
    #expect(
        family.contains(
            executablePath: "/Applications/Google Chrome.app/Contents/Frameworks/X.framework"
                + "/Helpers/Helper.app/Contents/MacOS/Helper"
        )
    )
    #expect(!family.contains(executablePath: "/Applications/Safari.app/Contents/MacOS/Safari"))

    let tool = ProcessFamilyKey.executable("node")
    #expect(tool.contains(executablePath: "/usr/local/bin/node"))
    #expect(!tool.contains(executablePath: "/usr/local/bin/deno"))
}

@Test func theDisplayNameDropsTheExtension() {
    let family = ProcessFamilyKey.bundle(
        identifier: "com.google.Chrome",
        appURL: URL(fileURLWithPath: "/Applications/Google Chrome.app", isDirectory: true)
    )
    #expect(family.displayName == "Google Chrome")
    #expect(ProcessFamilyKey.executable("node").displayName == "node")
}

// MARK: - The probe, live

@Test func theProbeFindsItsOwnFamily() {
    guard let family = ProcessFamilyKey.resolve(pid: getpid()) else {
        Issue.record("own pid must resolve")
        return
    }
    var probe = ProcessProbe(family: family)
    _ = probe.sample()

    guard let reading = probe.sample() else {
        Issue.record("second sample should produce a reading")
        return
    }
    let own = reading.members.first { $0.pid == getpid() }
    #expect(own != nil)
    #expect(own?.isOwnUser == true)
    #expect((own?.runningFor ?? 0) > 0)
    #expect((own?.footprint ?? 0) > 0)
    #expect(reading.footprint >= (own?.footprint ?? 0))
}

@Test func aFamilyNobodyRunsReadsAsExited() {
    var probe = ProcessProbe(family: .executable("caliper-no-such-process"))
    _ = probe.sample()
    guard let reading = probe.sample() else {
        Issue.record("second sample should produce a reading")
        return
    }
    #expect(reading.members.isEmpty)
}

// MARK: - Termination

@Test func aSignalNeverGoesToAStranger() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["60"]
    try child.run()
    let pid = child.processIdentifier

    guard let counters = ResourceUsage.counters(for: pid) else {
        child.terminate()
        Issue.record("own child must be readable")
        return
    }

    // A stale identity is "already exited", never a signal.
    #expect(
        ProcessProbe.terminate(pid: pid, startedAt: counters.startTime &+ 1, force: false)
            == .alreadyExited
    )

    #expect(
        ProcessProbe.terminate(pid: pid, startedAt: counters.startTime, force: false)
            == .signalled
    )
    child.waitUntilExit()
    #expect(child.terminationStatus != 0 || child.terminationReason == .uncaughtSignal)

    // The pid is free again; the identity check keeps the second signal home.
    #expect(
        ProcessProbe.terminate(pid: pid, startedAt: counters.startTime, force: true)
            == .alreadyExited
    )
}

@Test func anotherUsersProcessIsRefused() {
    // launchd is pid 1, root's, and must never be signalled: unreadable but
    // alive reads as refused, not as exited.
    #expect(ProcessProbe.terminate(pid: 1, startedAt: 1, force: false) == .refused)
}
