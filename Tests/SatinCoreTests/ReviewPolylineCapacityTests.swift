import SatinCore
import simd
import XCTest

/// Review evidence for Satin#58: generatePolylineGeometryData sizes its storage from
/// `capStyle == 2`, but draws a round cap for every capStyle other than 0 and 1.
/// Writes past the allocation, so run it on its own:
/// `swift test -c release -j 8 -Xswiftc -enable-testing --scratch-path .build.noindex --filter ReviewPolylineCapacityTests`.
final class ReviewPolylineCapacityTests: XCTestCase {
    func testOutOfRangeCapStyleOutgrowsItsStorage() {
        let capStyle = Int32(ProcessInfo.processInfo.environment["CAPPROBE_STYLE"] ?? "3") ?? 3
        var data = createPolylineGeometryData()
        defer { freePolylineGeometryData(&data) }
        let points: [simd_float3] = [[0, 0, 0], [1, 0, 0]]
        points.withUnsafeBufferPointer { buffer in
            generatePolylineGeometryData(&data, buffer.baseAddress, 2, false, 0.2, 1, capStyle, 4, [0, 0, 1], 8, nil, 0, nil, 0)
        }
        print("CAPPROBE capStyle=\(capStyle) vertexCount=\(data.vertexCount) vertexCapacity=\(data.vertexCapacity) triangleCount=\(data.indexCount) triangleCapacity=\(data.indexCapacity)")
    }
}
