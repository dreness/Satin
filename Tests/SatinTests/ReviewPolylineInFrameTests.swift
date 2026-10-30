import Metal
@testable import Satin
import simd
import XCTest

/// Review evidence for Satin#58, round 2: several updates inside one frame (an Iterator drawing one
/// geometry with different points per iteration). Each upload must go to its own buffer, and an
/// earlier iteration's buffer must keep its contents after later updates.
/// Run: `swift test -c release -j 10 -Xswiftc -enable-testing --scratch-path .build.noindex --filter ReviewPolylineInFrameTests`.
final class ReviewPolylineInFrameTests: XCTestCase {
    func testUpdatesWithinOneFrameKeepEarlierBuffers() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let geometry = PolylineGeometry(context: Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm))
        let style = PolylineStyle(width: 0.05)
        var uploads: [(buffer: MTLBuffer, snapshot: [UInt8])] = []
        for iteration in 0 ..< 6 {
            let points = ContiguousArray((0 ..< 50).map { index in
                simd_float3(Float(index) * 0.01, sin(Float(index) * 0.3 + Float(iteration)), 0)
            })
            geometry.update(points: points, closed: false, style: style)
            geometry.update()
            let buffer = try XCTUnwrap(geometry.vertexBuffers[.Vertices])
            let bytes = UnsafeRawBufferPointer(start: buffer.contents(), count: buffer.length)
            uploads.append((buffer, Array(bytes)))
        }
        for (iteration, upload) in uploads.enumerated() {
            let current = Array(UnsafeRawBufferPointer(start: upload.buffer.contents(), count: upload.buffer.length))
            let sharesBufferWith = uploads[..<iteration].firstIndex { $0.buffer === upload.buffer }
            print("INFRAME iteration=\(iteration) shares_buffer_with=\(sharesBufferWith.map(String.init) ?? "none") contents_unchanged=\(current == upload.snapshot)")
            XCTAssertNil(sharesBufferWith)
            XCTAssertEqual(current, upload.snapshot)
        }
    }
}
