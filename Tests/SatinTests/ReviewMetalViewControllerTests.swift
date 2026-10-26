#if os(macOS)
import AppKit
import Metal
@testable import Satin
import XCTest

/// Finding 8: with a renderQueue, cleanup is async, so a second controller reusing the renderer
/// sees isSetup still true and skips setup. Also: drawnSize survives cleanup+setup.
final class ReviewMetalViewControllerTests: XCTestCase {
    private final class CountingRenderer: ViewRenderer {
        var setups = 0
        var cleanups = 0
        var resizes = 0
        override func setup() throws { setups += 1 }
        override func cleanup() throws { cleanups += 1 }
        override func resize(size: (width: Float, height: Float), scaleFactor: Float) { resizes += 1 }
    }

    func testSecondControllerWithSameRendererIsSetUp() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = DispatchQueue(label: "Review Render Queue")
        let renderer = CountingRenderer(context: Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm), renderQueue: queue)

        autoreleasepool {
            let first = MetalViewController(renderer: renderer)
            _ = first.view
            XCTAssertTrue(renderer.isSetup)
        } // first deinit -> cleanup -> renderQueue.async { cleanup }

        let second = MetalViewController(renderer: renderer)
        _ = second.view
        queue.sync {} // drain the queued cleanup
        let delegateIsRenderer = second.metalView.delegate === renderer
        print("REVIEW8 unforced: isSetup \(renderer.isSetup), setups \(renderer.setups), cleanups \(renderer.cleanups), delegate \(delegateIsRenderer)")
        withExtendedLifetime(second) {}
    }

    /// Holds the render queue so A's queued cleanup is still pending when B loads.
    func testSecondControllerWhileCleanupPending() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = DispatchQueue(label: "Review Render Queue Held")
        let gate = DispatchSemaphore(value: 0)
        let renderer2 = CountingRenderer(context: Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm), renderQueue: queue)
        var first: MetalViewController? = MetalViewController(renderer: renderer2)
        _ = first?.view
        queue.async { gate.wait() }
        first = nil
        let isSetupWhilePending = renderer2.isSetup
        let second = MetalViewController(renderer: renderer2)
        _ = second.view
        let setupsBeforeDrain = renderer2.setups
        gate.signal()
        queue.sync {}
        let delegateIsRenderer = second.metalView.delegate === renderer2
        print("REVIEW8 held: isSetup while cleanup pending \(isSetupWhilePending), setups before drain \(setupsBeforeDrain), after drain: isSetup \(renderer2.isSetup), setups \(renderer2.setups), cleanups \(renderer2.cleanups), B.metalView.delegate is renderer \(delegateIsRenderer)")
        XCTAssertTrue(renderer2.isSetup, "renderer left un-set-up")
        XCTAssertTrue(delegateIsRenderer, "B's view never drives the renderer")
        withExtendedLifetime(second) {}
    }

    func testResizeAfterCleanupAndSetupAtSameSize() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = CountingRenderer(context: Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm),
                                        renderQueue: DispatchQueue(label: "Review Resize Queue"))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 100, height: 50, mipmapped: false)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        try renderer.setup()
        renderer.resizeIfNeeded(for: texture)
        try renderer.cleanup()
        try renderer.setup()
        renderer.resizeIfNeeded(for: texture)
        print("REVIEW8b resizes for setup, draw 100x50, cleanup, setup, draw 100x50: \(renderer.resizes)")
        XCTAssertEqual(renderer.resizes, 2, "no resize after re-setup at the same size")
    }
}
#endif
