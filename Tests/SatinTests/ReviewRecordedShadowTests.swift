@testable import Satin
import Metal
import simd
import XCTest

/// Finding 6: per-record shadow map allocation. Finding 7: recorded casters skip shadow.mayReach.
final class ReviewRecordedShadowTests: XCTestCase {
    private var device: MTLDevice!
    private var context: Context!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                          depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
    }

    private func makeTarget() throws -> MTLRenderPassDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        return pass
    }

    private func makeSubmission(_ renderer: RenderEncoder) -> SubmissionBuilder {
        let camera = PerspectiveCamera(context: context, position: [0, 0, 5], near: 0.1, far: 100, fov: 45)
        camera.aspect = 1
        return renderer.makeSubmissionBuilder(frame: .zero, cameras: [camera],
                                              viewports: [.init(originX: 0, originY: 0, width: 64, height: 64, znear: 0, zfar: 1)])
    }

    private func makeReceiver() -> Mesh {
        let plane = PlaneGeometry(context: context)
        plane.width = 4
        plane.height = 4
        let mesh = Mesh(context: context, geometry: plane, material: BasicDiffuseMaterial(context: context))
        mesh.position.z = -0.75
        mesh.receiveShadow = true
        return mesh
    }

    private func makeBox() -> Mesh {
        let mesh = Mesh(context: context, geometry: BoxGeometry(context: context), material: BasicDiffuseMaterial(context: context))
        mesh.scale = .init(repeating: 0.35)
        mesh.castShadow = true
        mesh.receiveShadow = true
        return mesh
    }

    // MARK: - 6

    private func recordShadowedLight(times: Int, moveLight: Bool) throws -> (textures: Int, bytesGrowth: Int, bytesAfterCompletion: Int) {
        let renderer = RenderEncoder(context: context)
        renderer.resize((width: 64, height: 64))
        let light = DirectionalLight(context: context, color: .one)
        light.position = [2, 3, 5]
        light.lookAt(target: .zero)
        light.castShadow = true
        light.shadow.resolution = (1024, 1024)
        let box = makeBox()
        let scene = Object(context: context, label: "Iterated", [light, box])
        let root = Object(context: context, label: "Root", [makeReceiver()])

        // Warm up once so pipeline/shadow setup isn't counted.
        do {
            let submission = makeSubmission(renderer)
            try submission.record(scene: scene)
            let commands = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
            try submission.record(scene: root, renderPassDescriptor: try makeTarget(), preparationCommandBuffer: commands)
            try submission.seal().encode(into: commands)
            commands.commit()
            commands.waitUntilCompleted()
        }

        let before = device.currentAllocatedSize
        let submission = makeSubmission(renderer)
        for index in 0 ..< times {
            if moveLight { light.position = [2 + Float(index) * 0.01, 3, 5]; light.lookAt(target: .zero) }
            box.position.x = Float(index % 5) * 0.1
            box.update()
            try submission.record(scene: scene)
        }
        var textures = Set<ObjectIdentifier>()
        for occurrence in submission.lightOccurrences {
            for texture in occurrence.shadow.textures { textures.insert(ObjectIdentifier(texture)) }
        }
        let growth = device.currentAllocatedSize - before
        let commands = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        try submission.record(scene: root, renderPassDescriptor: try makeTarget(), preparationCommandBuffer: commands)
        try submission.seal().encode(into: commands)
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed, String(describing: commands.error))
        return (textures.count, growth, device.currentAllocatedSize - before)
    }

    func testShadowMapsAllocatedPerRecord() throws {
        for moveLight in [false, true] {
            for times in [1, 50] {
                let result = try recordShadowedLight(times: times, moveLight: moveLight)
                print("REVIEW6 records \(times) moveLight \(moveLight): distinct shadow textures \(result.textures), currentAllocatedSize growth while recording \(result.bytesGrowth / 1024) KB, after completion \(result.bytesAfterCompletion / 1024) KB (1024x1024 depth32 = 4096 KB)")
            }
        }
    }

    // MARK: - 7

    /// Shadow encoder draw ranges, by reading SealedSubmission's private `passes` via Mirror.
    private func shadowDraws(_ sealed: SealedSubmission) -> (passes: Int, packets: Int) {
        var passCount = 0
        var packetCount = 0
        for child in Mirror(reflecting: sealed).children where child.label == "passes" {
            guard let passes = child.value as? [RecordedRenderPass] else { continue }
            for pass in passes where pass.label.contains("Shadow") {
                passCount += 1
                for command in pass.commands {
                    switch command {
                        case let .range(range, _): packetCount += range.count
                        case let .indices(indices, _): packetCount += indices.count
                        default: break
                    }
                }
            }
        }
        return (passCount, packetCount)
    }

    private func pointShadowDraws(casterRecorded: Bool, casterInReach: Bool) throws -> (passes: Int, packets: Int) {
        let renderer = RenderEncoder(context: context)
        renderer.resize((width: 64, height: 64))
        let light = PointLight(context: context, color: .one, radius: 2)
        light.position = [0, 0, 1]
        light.castShadow = true
        light.shadow.resolution = (64, 64)
        let receiver = makeReceiver()
        let near = makeBox()
        near.position = [0.5, 0, 0]
        let caster = makeBox()
        // Far outside the light's 2-unit reach, but along +x so the +x face's side planes contain it.
        caster.position = casterInReach ? [1, 0, 1] : [20, 0, 1]
        let root = Object(context: context, label: "Root", [receiver, light, near])
        let submission = makeSubmission(renderer)
        if casterRecorded {
            caster.update()
            try submission.record(scene: Object(context: context, label: "Recorded", [caster]))
        } else {
            root.add(caster)
        }
        let commands = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        try submission.record(scene: root, renderPassDescriptor: try makeTarget(), preparationCommandBuffer: commands)
        let sealed = try submission.seal()
        let counts = shadowDraws(sealed)
        try sealed.encode(into: commands)
        commands.commit()
        commands.waitUntilCompleted()
        return counts
    }

    func testRecordedCastersOutOfPointLightReachAreEncoded() throws {
        let rootOut = try pointShadowDraws(casterRecorded: false, casterInReach: false)
        let recordedOut = try pointShadowDraws(casterRecorded: true, casterInReach: false)
        let rootIn = try pointShadowDraws(casterRecorded: false, casterInReach: true)
        let recordedIn = try pointShadowDraws(casterRecorded: true, casterInReach: true)
        print("REVIEW7 shadow (passes, packets): out-of-reach caster in root \(rootOut), recorded \(recordedOut); in-reach caster in root \(rootIn), recorded \(recordedIn)")
        XCTAssertEqual(rootOut.packets, recordedOut.packets, "a recorded caster beyond the point light's reach is still encoded")
    }
}
