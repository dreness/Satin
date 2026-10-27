#if os(macOS)
import AppKit
import Metal
@testable import Satin
import XCTest

/// Finding 8 (renderQueue async cleanup, drawnSize surviving re-setup) went away with the render
/// queue. What remains: a second controller reusing a renderer sets it up again.
final class ReviewMetalViewControllerTests: XCTestCase {
    private final class CountingRenderer: ViewRenderer {
        var setups = 0
        var cleanups = 0
        override func setup() throws { setups += 1 }
        override func cleanup() throws { cleanups += 1 }
    }

    func testSecondControllerWithSameRendererIsSetUp() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = CountingRenderer(context: Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm))

        autoreleasepool {
            let first = MetalViewController(renderer: renderer)
            _ = first.view
            XCTAssertTrue(renderer.isSetup)
        }

        let second = MetalViewController(renderer: renderer)
        _ = second.view
        let delegateIsRenderer = second.metalView.delegate === renderer
        print("REVIEW8: isSetup \(renderer.isSetup), setups \(renderer.setups), cleanups \(renderer.cleanups), delegate \(delegateIsRenderer)")
        XCTAssertTrue(renderer.isSetup)
        XCTAssertEqual(renderer.setups, 2)
        withExtendedLifetime(second) {}
    }
}
#endif
