import SatinCore
import simd
import XCTest

/// Review evidence for Satin#58, round 2: out-of-range join and cap styles through the C API stay
/// inside the storage generatePolylineGeometryData sizes for them.
/// Run: `swift test -c release -j 10 -Xswiftc -enable-testing --scratch-path .build.noindex --filter ReviewPolylineCapacityTests`.
final class ReviewPolylineCapacityTests: XCTestCase {
    func testOutOfRangeStylesStayInsideTheirStorage() {
        let points: [simd_float3] = [[0, 0, 0], [1, 0, 0], [1, 1, 0], [0, 1, 0]]
        for (joinStyle, capStyle) in [(1, 3), (1, 99), (1, -1), (3, 0), (-1, 2), (99, 99)] as [(Int32, Int32)] {
            var data = createPolylineGeometryData()
            defer { freePolylineGeometryData(&data) }
            points.withUnsafeBufferPointer { buffer in
                generatePolylineGeometryData(&data, buffer.baseAddress, Int32(buffer.count), false, 0.2, joinStyle, capStyle, 4, [0, 0, 1], 8, nil, 0, nil, 0)
            }
            print("CAPPROBE joinStyle=\(joinStyle) capStyle=\(capStyle) vertexCount=\(data.vertexCount) vertexCapacity=\(data.vertexCapacity) triangleCount=\(data.indexCount) triangleCapacity=\(data.indexCapacity)")
            XCTAssertLessThanOrEqual(data.vertexCount, data.vertexCapacity)
            XCTAssertLessThanOrEqual(data.indexCount, data.indexCapacity)
        }
    }
}
