@testable import Satin
import Metal
import XCTest

/// Finding 4: TessellationMesh binds factors that nothing wrote when the real
/// TessellationProcessor.update(_:) returns early (no pipeline), and clears its freeze request
/// whether or not the freeze dispatched.
final class ReviewTessellationTests: XCTestCase {
    private var device: MTLDevice!
    private var context: Context!
    private var commandQueue: MTLCommandQueue!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float)
        commandQueue = try XCTUnwrap(device.makeCommandQueue())
    }

    /// The real processor; only counts calls and whether a pipeline was available.
    final class CountingTessellator: TessellationProcessor<MTLTriangleTessellationFactorsHalf> {
        var calls = 0
        var callsWithPipeline = 0
        override func update(_ commandBuffer: MTLCommandBuffer, iterations: Int = 1) {
            calls += 1
            super.update(commandBuffer, iterations: iterations)
            if resetPipeline != nil || updatePipeline != nil { callsWithPipeline += 1 }
        }
    }

    private func makeMesh(tessellate: Bool) -> (TessellationMesh, CountingTessellator) {
        let geometry = TessellationGeometry(baseGeometry: QuadGeometry(context: context, size: 1.0))
        let tessellator = CountingTessellator(device: device,
                                              pipelineURL: FileManager.default.temporaryDirectory.appending(path: "ReviewMissingTessellator.metal"),
                                              live: false, geometry: geometry)
        let mesh = TessellationMesh(context: context, label: "Tessellated", geometry: geometry, material: nil, tessellator: tessellator, tessellate: tessellate)
        return (mesh, tessellator)
    }

    private func submission(_ encoder: RenderEncoder) -> SubmissionBuilder {
        let camera = PerspectiveCamera(context: context, position: [0, 0, 5], near: 0.1, far: 100, fov: 30)
        return encoder.makeSubmissionBuilder(frame: .zero, cameras: [camera], viewports: [MTLViewport(originX: 0, originY: 0, width: 64, height: 64, znear: 0, zfar: 1)])
    }

    func testTessellatingWithoutPipelineBindsUnwrittenSlice() throws {
        let encoder = RenderEncoder(context: context)
        let (mesh, tessellator) = makeMesh(tessellate: true)
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        let builder = submission(encoder)
        mesh.encode(in: builder.encodingContext(commandBuffer: commandBuffer))
        let factors = try XCTUnwrap(mesh.encodedFactors, "draw binds a factors slice")
        let length = tessellator.factorsLength
        let bytes = factors.buffer.contents().advanced(by: factors.offset).assumingMemoryBound(to: UInt8.self)
        let initial = Array(UnsafeBufferPointer(start: bytes, count: min(length, 16)))
        // Sentinel: if the GPU wrote factors, it would replace these bytes.
        bytes.initialize(repeating: 0xAB, count: length)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        let after = Array(UnsafeBufferPointer(start: bytes, count: length))
        print("REVIEW4 tessellate=true: update calls \(tessellator.calls), with pipeline \(tessellator.callsWithPipeline), encodedFactors set \(mesh.encodedFactors != nil), storage \(factors.buffer.storageMode.rawValue), slice first bytes before sentinel \(initial), sentinel intact after GPU \(after.allSatisfy { $0 == 0xAB }) (\(length) bytes)")
        XCTAssertEqual(tessellator.callsWithPipeline, 0)
        XCTAssertFalse(after.allSatisfy { $0 == 0xAB }, "the slice the draw binds was never written")
    }

    func testFreezeWithoutPipelineIsNotRetried() throws {
        let encoder = RenderEncoder(context: context)
        let (mesh, tessellator) = makeMesh(tessellate: false)
        let commandBuffer = try XCTUnwrap(commandQueue.makeCommandBuffer())
        let builder = submission(encoder)
        mesh.encode(in: builder.encodingContext(commandBuffer: commandBuffer))
        let firstCalls = tessellator.calls
        let frozen = mesh.encodedFactors
        mesh.encode(in: builder.encodingContext(commandBuffer: commandBuffer))
        mesh.encode(in: builder.encodingContext(commandBuffer: commandBuffer))
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        print("REVIEW4 tessellate=false: update calls after first encode \(firstCalls), after three encodes \(tessellator.calls), with pipeline \(tessellator.callsWithPipeline), frozen buffer bound \(frozen != nil) storage \(frozen.map { Int($0.buffer.storageMode.rawValue) } ?? -1)")
        XCTAssertGreaterThan(tessellator.calls, firstCalls, "a failed freeze is never retried")
    }
}
