import Metal
@testable import Satin
import simd
import XCTest

/// Review evidence for Satin#58. Compiles on the PR head and on the PR merged into main.
/// Run: `swift test -c release -j 8 -Xswiftc -enable-testing --scratch-path .build.noindex --filter ReviewPolylineTests`.
/// Env: POLYBENCH_SIZES (comma list, default 100,1000,10000), POLYBENCH_ITERATIONS (default 200),
/// POLYBENCH_TREE (label printed with each line).
final class ReviewPolylineTests: XCTestCase {
    static func makeGeometry() throws -> PolylineGeometry {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return PolylineGeometry(context: Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm))
    }

    static func zigzag(count: Int, phase: Float) -> ContiguousArray<simd_float3> {
        ContiguousArray((0 ..< count).map { index in
            simd_float3(Float(index) * 0.01, sin(Float(index) * 0.3 + phase), 0)
        })
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// .dynamicData (the PolylineGeometry default) vs .staticData. On the PR head these are the
    /// versioned ring vs a new MTLBuffer per update; on main both make a new MTLBuffer per update.
    func testUpdateCost() throws {
        let environment = ProcessInfo.processInfo.environment
        let sizes = (environment["POLYBENCH_SIZES"] ?? "100,1000,10000").split(separator: ",").compactMap { Int($0) }
        let iterations = Int(environment["POLYBENCH_ITERATIONS"] ?? "200") ?? 200
        let tree = environment["POLYBENCH_TREE"] ?? "unknown"
        let style = PolylineStyle(width: 0.05, join: .round, cap: .round)

        for size in sizes {
            for mutability in [GeometryMutability.dynamicData, .staticData] {
                let geometry = try Self.makeGeometry()
                geometry.mutability = mutability
                var tessellateTimes: [Double] = []
                var uploadTimes: [Double] = []
                var distinctBuffers = Set<ObjectIdentifier>()
                for iteration in 0 ..< iterations {
                    let points = Self.zigzag(count: size, phase: Float(iteration) * 0.01)
                    let tessellateStart = DispatchTime.now().uptimeNanoseconds
                    geometry.update(points: points, closed: false, style: style)
                    let uploadStart = DispatchTime.now().uptimeNanoseconds
                    geometry.update()
                    let uploadEnd = DispatchTime.now().uptimeNanoseconds
                    tessellateTimes.append(Double(uploadStart - tessellateStart) / 1000)
                    uploadTimes.append(Double(uploadEnd - uploadStart) / 1000)
                    if let buffer = geometry.vertexBuffers[.Vertices] { distinctBuffers.insert(ObjectIdentifier(buffer)) }
                }
                let label = mutability == .dynamicData ? "dynamic" : "static"
                print("POLYBENCH tree=\(tree) points=\(size) mutability=\(label) vertices=\(geometry.vertexCount) tessellate_us_median=\(String(format: "%.1f", median(tessellateTimes))) upload_us_median=\(String(format: "%.1f", median(uploadTimes))) distinct_vertex_buffers=\(distinctBuffers.count) iterations=\(iterations)")
            }
        }
    }
}
