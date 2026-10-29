import Metal
@testable import Satin
import simd
import XCTest

/// Review evidence for Satin#58, PR head only: `vertexBufferOffsets` and the versioned ring do not
/// exist on main. Several updates inside one frame (an Iterator drawing one geometry with
/// different points per iteration): the ring has maxBuffersInFlight slots and advances once per
/// `update()`, so with minimumEncodesPerFrame left at 1 a later update writes where an earlier
/// iteration's draw, encoded but not yet executed, reads.
/// Run: `swift test -c release -j 8 -Xswiftc -enable-testing --scratch-path .build.noindex --filter ReviewPolylineRingTests`.
final class ReviewPolylineRingTests: XCTestCase {
    func testUpdatesWithinOneFrameReuseSlots() throws {
        let geometry = try ReviewPolylineTests.makeGeometry()
        let style = PolylineStyle(width: 0.05)
        var slots: [(buffer: ObjectIdentifier, offset: Int)] = []
        for iteration in 0 ..< 6 {
            geometry.update(points: ReviewPolylineTests.zigzag(count: 50, phase: Float(iteration)), closed: false, style: style)
            geometry.update()
            let buffer = try XCTUnwrap(geometry.vertexBuffers[.Vertices])
            slots.append((ObjectIdentifier(buffer), geometry.vertexBufferOffsets[.Vertices] ?? -1))
        }
        for (iteration, slot) in slots.enumerated() {
            let firstReuse = slots[..<iteration].firstIndex { $0.buffer == slot.buffer && $0.offset == slot.offset }
            print("ITERSLOT iteration=\(iteration) offset=\(slot.offset) maxBuffersInFlight=\(geometry.context.maxBuffersInFlight) overwrites_iteration=\(firstReuse.map(String.init) ?? "none")")
        }
    }
}
