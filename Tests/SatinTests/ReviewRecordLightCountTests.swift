@testable import Satin
import Metal
import simd
import XCTest

/// Finding 3: records with different light sets than the frame. Each record writes its own light
/// counts / shadow indices onto the live (shared) material and lights.
final class ReviewRecordLightCountTests: XCTestCase {
    private var device: MTLDevice!
    private var context: Context!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                          depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
    }

    private struct Case {
        let name: String
        // Light sets per record, in record order; one shared mesh/material across records.
        let recordLights: [[LightSpec]]
    }

    private struct LightSpec {
        let position: simd_float3
        let color: simd_float3
        let shadowed: Bool
        let point: Bool
    }

    func testRecordsWithDifferentLightSetsMatchStaticScene() throws {
        let red = LightSpec(position: [-2, 2, 4], color: [1, 0, 0], shadowed: false, point: true)
        let green = LightSpec(position: [2, 2, 4], color: [0, 1, 0], shadowed: false, point: true)
        let shadowA = LightSpec(position: [2, 3, 5], color: [1, 1, 1], shadowed: true, point: false)
        let shadowB = LightSpec(position: [-3, 2, 5], color: [0.6, 0.6, 1], shadowed: true, point: false)
        let cases = [
            Case(name: "1 light then 2 lights", recordLights: [[red], [red, green]]),
            Case(name: "2 lights then 1 light", recordLights: [[red, green], [green]]),
            Case(name: "0 lights then 1 light", recordLights: [[], [red]]),
            Case(name: "unshadowed then shadowed", recordLights: [[red], [shadowA]]),
            Case(name: "shadowed A then shadowed B", recordLights: [[shadowA], [shadowB]]),
            Case(name: "shadowed A then unshadowed+shadowed B", recordLights: [[shadowA], [red, shadowB]]),
        ]
        var failures: [String] = []
        for testCase in cases {
            let (recorded, reference) = try renderCase(testCase)
            let differing = stride(from: 0, to: recorded.count, by: 4).filter { pixel in
                (0 ..< 3).contains { channel in abs(Int(recorded[pixel + channel]) - Int(reference[pixel + channel])) > 2 }
            }.count
            let maxDelta = zip(recorded, reference).map { abs(Int($0) - Int($1)) }.max() ?? 0
            let litReference = stride(from: 0, to: reference.count, by: 4).filter { reference[$0] > 0 || reference[$0 + 1] > 0 || reference[$0 + 2] > 0 }.count
            print("REVIEW3 \(testCase.name): differing pixels \(differing)/\(64 * 64), max channel delta \(maxDelta), lit reference pixels \(litReference)")
            if differing > 0 { failures.append(testCase.name) }
        }
        XCTAssertEqual(failures, [])
    }

    private func makeLight(_ spec: LightSpec) -> Light {
        if spec.point {
            let light = PointLight(context: context, color: spec.color, radius: 20)
            light.position = spec.position
            return light
        }
        let light = DirectionalLight(context: context, color: spec.color)
        light.position = spec.position
        light.lookAt(target: .zero)
        light.castShadow = spec.shadowed
        light.shadow.resolution = (128, 128)
        light.shadow.radius = 0
        light.shadow.strength = 1
        return light
    }

    private func renderCase(_ testCase: Case) throws -> ([UInt8], [UInt8]) {
        let positions: [Float] = [-0.55, 0.55]
        // Recorded: one live mesh/material re-recorded with each record's lights.
        let material = BasicDiffuseMaterial(context: context)
        let mesh = makeBox(material: material)
        let recordScenes: [Object] = testCase.recordLights.map { specs in
            Object(context: context, label: "Record", specs.map(makeLight))
        }
        let recordedRoot = Object(context: context, label: "Root", [makeReceiver()])
        let recorded = try render(root: recordedRoot) { submission in
            for (index, scene) in recordScenes.enumerated() {
                mesh.position.x = positions[index]
                scene.add(mesh)
                mesh.update()
                try submission.record(scene: scene)
                scene.remove(mesh)
            }
        }

        let referenceRoot = Object(context: context, label: "Reference", [makeReceiver()])
        for (index, specs) in testCase.recordLights.enumerated() {
            let mesh = makeBox(material: BasicDiffuseMaterial(context: context))
            mesh.position.x = positions[index]
            referenceRoot.add(mesh)
            for spec in specs { referenceRoot.add(makeLight(spec)) }
        }
        let reference = try render(root: referenceRoot)
        return (recorded, reference)
    }

    private func makeBox(material: Material) -> Mesh {
        let mesh = Mesh(context: context, geometry: BoxGeometry(context: context), material: material)
        mesh.scale = .init(repeating: 0.35)
        mesh.castShadow = true
        mesh.receiveShadow = true
        return mesh
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

    private func render(root: Object, records: ((SubmissionBuilder) throws -> Void)? = nil) throws -> [UInt8] {
        let renderer = RenderEncoder(context: context)
        renderer.sortObjects = true
        renderer.resize((width: 64, height: 64))
        let camera = PerspectiveCamera(context: context, position: [0, 0, 5], near: 0.1, far: 100, fov: 45)
        camera.aspect = 1
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        let commands = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
        let submission = renderer.makeSubmissionBuilder(frame: .zero, cameras: [camera],
                                                        viewports: [.init(originX: 0, originY: 0, width: 64, height: 64, znear: 0, zfar: 1)])
        try records?(submission)
        try submission.record(scene: root, renderPassDescriptor: pass, preparationCommandBuffer: commands)
        try submission.seal().encode(into: commands)
        commands.commit()
        commands.waitUntilCompleted()
        XCTAssertEqual(commands.status, .completed, String(describing: commands.error))
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        bytes.withUnsafeMutableBytes { bytes in
            if let address = bytes.baseAddress {
                texture.getBytes(address, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            }
        }
        return bytes
    }
}
