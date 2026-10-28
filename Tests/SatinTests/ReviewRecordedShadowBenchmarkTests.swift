@testable import Satin
import Metal
import XCTest

/// Evidence for PR #68: cost of recording moving shadowed lights each frame. Identical source
/// compiles against base and PR. SATIN_TREE labels output; SATIN_SHADOW_LIGHTS and
/// SATIN_SHADOW_RESOLUTION set the light count and map size.
final class ReviewRecordedShadowBenchmarkTests: XCTestCase {
    private static let environment = ProcessInfo.processInfo.environment
    private static let tree = environment["SATIN_TREE"] ?? "unknown"
    private static let lightCount = Int(environment["SATIN_SHADOW_LIGHTS"] ?? "") ?? 50
    private static let shadowResolution = Int(environment["SATIN_SHADOW_RESOLUTION"] ?? "") ?? 1024

    private static func threadCPUNanoseconds() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// Device memory for one context drawing one mesh into a 64x64 target, no shadows.
    func testMinimalRendererFootprint() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let baselineBytes = device.currentAllocatedSize
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float)
        let renderer = RenderEncoder(context: context)
        renderer.resize((width: 64, height: 64))
        let mesh = Mesh(context: context, geometry: BoxGeometry(context: context), material: BasicDiffuseMaterial(context: context))
        let camera = PerspectiveCamera(context: context, position: [0, 0, 5], near: 0.1, far: 100, fov: 45)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = .renderTarget
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        for _ in 0 ..< 3 {
            let submission = renderer.makeSubmissionBuilder(frame: .zero, cameras: [camera],
                                                            viewports: [.init(originX: 0, originY: 0, width: 64, height: 64, znear: 0, zfar: 1)])
            let commands = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
            try submission.record(scene: Object(context: context, label: "Root", [mesh]), renderPassDescriptor: pass, preparationCommandBuffer: commands)
            try submission.seal().encode(into: commands)
            commands.commit()
            commands.waitUntilCompleted()
        }
        print(String(format: "FOOTPRINT tree=%@ MB=%.1f", Self.tree, Double(device.currentAllocatedSize - baselineBytes) / 1_048_576))
    }

    func testRecordedShadowBenchmark() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let baselineBytes = device.currentAllocatedSize
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float)
        let renderer = RenderEncoder(context: context)
        renderer.resize((width: 256, height: 256))
        let lights = (0 ..< Self.lightCount).map { _ in
            let light = PointLight(context: context, color: .one, radius: 4)
            light.castShadow = true
            light.shadow.resolution = (Self.shadowResolution, Self.shadowResolution)
            return light
        }
        let receiver = Mesh(context: context, geometry: PlaneGeometry(context: context), material: BasicDiffuseMaterial(context: context))
        receiver.receiveShadow = true
        let caster = Mesh(context: context, geometry: BoxGeometry(context: context), material: BasicDiffuseMaterial(context: context))
        caster.scale = .init(repeating: 0.25)
        caster.castShadow = true
        let root = Object(context: context, label: "Root", [receiver, caster])
        let camera = PerspectiveCamera(context: context, position: [0, 0, 5], near: 0.1, far: 100, fov: 45)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 256, height: 256, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = .renderTarget
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let warmupFrames = 20, measuredFrames = 120
        let inFlight = DispatchSemaphore(value: 3)
        let gpuLock = NSLock()
        var cpuSamples: [Double] = []
        var gpuSamples: [Double] = []
        var peakBytes = 0
        for frame in 0 ..< (warmupFrames + measuredFrames) {
            inFlight.wait()
            let cpuBefore = Self.threadCPUNanoseconds()
            let submission = renderer.makeSubmissionBuilder(frame: .zero, cameras: [camera],
                                                            viewports: [.init(originX: 0, originY: 0, width: 256, height: 256, znear: 0, zfar: 1)])
            for (index, light) in lights.enumerated() {
                light.position = [Float(index % 10) * 0.1, Float(frame) * 0.01, 1]
                try submission.record(scene: Object(context: context, label: "Recorded Light \(index)", [light]))
            }
            let commands = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
            try submission.record(scene: root, renderPassDescriptor: pass, preparationCommandBuffer: commands)
            try submission.seal().encode(into: commands)
            commands.addCompletedHandler { buffer in
                if frame >= warmupFrames {
                    let gpu = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000
                    gpuLock.withLock { gpuSamples.append(gpu) }
                }
                inFlight.signal()
            }
            commands.commit()
            if frame >= warmupFrames { cpuSamples.append(Double(Self.threadCPUNanoseconds() - cpuBefore) / 1e6) }
            peakBytes = max(peakBytes, device.currentAllocatedSize - baselineBytes)
        }
        for _ in 0 ..< 3 { inFlight.wait() }
        for _ in 0 ..< 3 { inFlight.signal() }
        let cpu = cpuSamples.sorted()[cpuSamples.count / 2]
        let gpuSorted = gpuLock.withLock { gpuSamples.sorted() }
        let gpu = gpuSorted[gpuSorted.count / 2]
        print(String(format: "SHADOWBENCH tree=%@ lights=%d res=%d cpu_ms=%.3f gpu_ms=%.3f peak_MB=%.1f settled_MB=%.1f",
                     Self.tree, Self.lightCount, Self.shadowResolution, cpu, gpu,
                     Double(peakBytes) / 1_048_576, Double(device.currentAllocatedSize - baselineBytes) / 1_048_576))
    }
}
