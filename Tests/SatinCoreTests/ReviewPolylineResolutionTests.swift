import SatinCore
import simd
import XCTest

/// Review evidence for Satin#58, round 2: `roundResolution` is unbounded, and the storage size
/// `n * (2 * resolution + 3) + 2` is computed in `int`. Past INT_MAX it wraps negative, nothing is
/// allocated, and the first vertex is written through a null pointer (the assert is compiled out in
/// release). Skipped unless ROUNDPROBE_RESOLUTION is set; it crashes, so run it on its own:
/// `env ROUNDPROBE_RESOLUTION=600000000 swift test -c release -j 10 -Xswiftc -enable-testing --scratch-path .build.noindex --filter ReviewPolylineResolutionTests`.
final class ReviewPolylineResolutionTests: XCTestCase {
    func testHugeRoundResolutionOverflowsTheStorageSize() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let resolution = environment["ROUNDPROBE_RESOLUTION"].flatMap({ Int32($0) }) else {
            throw XCTSkip("set ROUNDPROBE_RESOLUTION")
        }
        let points: [simd_float3] = [[0, 0, 0], [1, 0, 0], [1, 1, 0]]
        let pointCount = Int32(points.count)
        let joinVertices = 2 &* resolution &+ 3
        let vertexCapacity = pointCount &* joinVertices &+ 2
        print("ROUNDPROBE resolution=\(resolution) points=\(pointCount) int_vertexCapacity=\(vertexCapacity) exact_vertexCapacity=\(Int64(pointCount) * (2 * Int64(resolution) + 3) + 2)")
        var data = createPolylineGeometryData()
        defer { freePolylineGeometryData(&data) }
        points.withUnsafeBufferPointer { buffer in
            generatePolylineGeometryData(&data, buffer.baseAddress, pointCount, false, 0.2, 2, 2, 4, [0, 0, 1], resolution, nil, 0, nil, 0)
        }
        print("ROUNDPROBE returned vertexCount=\(data.vertexCount) vertexCapacity=\(data.vertexCapacity)")
    }
}
