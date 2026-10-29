import AppKit
import Foundation
import Testing
@testable import DesktopGlow

@Test
func renderSchedulingPolicyScalesWithSpeedAndCapsCadence() {
    var configuration = DitherConfiguration()
    configuration.intro = false

    #expect(DitherRenderSchedulingPolicy.interval(for: configuration, introComplete: true) == 1.0 / 30.0)

    configuration.waveSpeed = 0.01
    let slowInterval = DitherRenderSchedulingPolicy.interval(for: configuration, introComplete: true) ?? 0
    #expect(abs(slowInterval - 1.0 / 6.0) < 0.000001)

    configuration.waveSpeed = 0
    #expect(DitherRenderSchedulingPolicy.interval(for: configuration, introComplete: true) == nil)

    configuration.waveSpeed = 0.01
    configuration.scale = 0.5
    let detailedInterval = DitherRenderSchedulingPolicy.interval(for: configuration, introComplete: true) ?? 0
    #expect(abs(detailedInterval - 1.0 / 12.0) < 0.000001)

    configuration.waveSpeed = 1
    #expect(DitherRenderSchedulingPolicy.interval(for: configuration, introComplete: true) == 1.0 / 30.0)

    configuration.waveSpeed = 0.0001
    #expect(DitherRenderSchedulingPolicy.interval(for: configuration, introComplete: true) == 0.25)
}

@Test
func introForcesThirtyFramesPerSecondUntilComplete() {
    var configuration = DitherConfiguration()
    configuration.waveSpeed = 0
    configuration.disableAnimation = true
    configuration.intro = true

    #expect(DitherRenderSchedulingPolicy.interval(for: configuration, introComplete: false) == 1.0 / 30.0)
    #expect(DitherRenderSchedulingPolicy.interval(for: configuration, introComplete: true) == nil)
}

@Test
func nonAdvancingRendersDoNotMoveTimingBoundary() {
    var timing = DitherAnimationTiming()
    timing.seed(now: 10)

    #expect(timing.advance(now: 10.25, isAdvancing: false) == 0)
    #expect(timing.advance(now: 10.5, isAdvancing: true) == 0.5)
}

@Test
@MainActor
func staticPreviewStopsTimerAfterItsInitialFrame() throws {
    _ = NSApplication.shared
    let view = DitherPreviewView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
    var configuration = DitherConfiguration()
    configuration.intro = false
    configuration.waveSpeed = 0
    view.setConfiguration(configuration)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 160, height: 90),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
        view.setActive(false)
        window.close()
    }
    window.contentView = view
    window.orderBack(nil)
    view.setActive(true)

    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    let settledFrameCount = view.renderedFrames
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))

    #expect(settledFrameCount > 0)
    // Reapplying desktop policy and identical settings must not wake static output.
    for _ in 0..<20 {
        view.setConfiguration(configuration)
        view.setActive(true)
    }
    #expect(view.renderedFrames == settledFrameCount)
    configuration.brightness = 0.1
    view.setConfiguration(configuration)
    #expect(view.renderedFrames == settledFrameCount + 1)
}

@Test
@MainActor
func activePreviewTimerStopsAndRestartsAcrossPause() throws {
    _ = NSApplication.shared
    let view = DitherPreviewView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
    var configuration = DitherConfiguration()
    configuration.intro = false
    configuration.waveSpeed = 0.05
    view.setConfiguration(configuration)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 160, height: 90),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
        view.setActive(false)
        window.close()
    }
    window.contentView = view
    window.orderBack(nil)
    view.setActive(true)

    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    view.setActive(false)
    let pausedFrameCount = view.renderedFrames
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    #expect(view.renderedFrames == pausedFrameCount)

    view.setActive(true)
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    #expect(view.renderedFrames > pausedFrameCount)
}

@Test
@MainActor
func introRendersAtThirtyFramesPerSecondThenStopsWhenStatic() throws {
    _ = NSApplication.shared
    let view = DitherPreviewView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
    var configuration = DitherConfiguration()
    configuration.waveSpeed = 0
    configuration.disableAnimation = true
    configuration.intro = true
    view.setConfiguration(configuration)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 160, height: 90),
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    defer {
        view.setActive(false)
        window.close()
    }
    window.contentView = view
    window.orderBack(nil)
    view.setActive(true)

    RunLoop.main.run(until: Date().addingTimeInterval(2.2))
    let settledFrameCount = view.renderedFrames
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))

    #expect(settledFrameCount > 30)
    #expect(view.renderedFrames == settledFrameCount)
}

@Test @MainActor
func introSwitchesToSlowCadenceAndConfigurationRestartsStaticOutput() throws {
    _ = NSApplication.shared
    let view = DitherPreviewView(frame: NSRect(x: 0, y: 0, width: 160, height: 90))
    var configuration = DitherConfiguration()
    configuration.waveSpeed = 0.01
    view.setConfiguration(configuration)
    let window = NSWindow(
        contentRect: view.frame,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderBack(nil)
    defer {
        view.setActive(false)
        window.close()
    }
    view.setActive(true)
    RunLoop.main.run(until: Date().addingTimeInterval(2.1))
    let afterIntro = view.renderedFrames
    RunLoop.main.run(until: Date().addingTimeInterval(0.55))
    let slowFrames = view.renderedFrames - afterIntro
    #expect(slowFrames >= 2 && slowFrames <= 4)

    configuration.waveSpeed = 0
    view.setConfiguration(configuration)
    let staticFrames = view.renderedFrames
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    #expect(view.renderedFrames == staticFrames)

    configuration.waveSpeed = 0.05
    view.setConfiguration(configuration)
    let restartedFrames = view.renderedFrames
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    #expect(view.renderedFrames > restartedFrames)
}
