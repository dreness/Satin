@testable import Satin
import Metal
import simd
import XCTest

final class ReviewLightABATests: XCTestCase {
    func testRecordedLightColorChangesAcrossFramesAreUploaded() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm,
                              depthPixelFormat: .depth32Float, stencilPixelFormat: .invalid)
        let renderer = RenderEncoder(context: context)
        renderer.resize((width: 16, height: 16))
        let camera = PerspectiveCamera(context: context, position: [0, 0, 5], near: 0.1, far: 100, fov: 45)
        camera.aspect = 1
        let mesh = Mesh(context: context, geometry: BoxGeometry(context: context), material: BasicDiffuseMaterial(context: context))
        let root = Object(context: context, label: "Root", [mesh])
        let light = PointLight(context: context, color: [1, 0, 0], radius: 10)
        light.position = [0, 0, 3]
        let lightScene = Object(context: context, label: "Lights", [light])

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        let colors: [simd_float3] = [[1, 0, 0], [0, 1, 0], [0, 0, 1], [1, 1, 0], [0, 1, 1], [1, 0, 1]]
        var stale = 0
        var retained: [SealedSubmission] = []
        for frame in 0 ..< 60 {
            let expected = colors[frame % colors.count]
            light.color = expected
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            let commands = try XCTUnwrap(context.commandQueue.makeCommandBuffer())
            let submission = renderer.makeSubmissionBuilder(frame: .zero, cameras: [camera],
                                                            viewports: [.init(originX: 0, originY: 0, width: 16, height: 16, znear: 0, zfar: 1)])
            try submission.record(scene: lightScene)
            try submission.record(scene: root, renderPassDescriptor: pass, preparationCommandBuffer: commands)
            let sealed = try submission.seal()
            try sealed.encode(into: commands)
            if ProcessInfo.processInfo.environment["RETAIN"] != nil { retained.append(sealed) }
            commands.commit()
            commands.waitUntilCompleted()
            let uploaded = renderer.uploadedLightData[0].color
            var pixel = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&pixel, bytesPerRow: 16 * 4, from: MTLRegionMake2D(8, 8, 1, 1), mipmapLevel: 0)
            if frame < 8 { print("REVIEW pixel bgra \(pixel)") }
            if frame < 8 { print("REVIEW frame \(frame) expected \(expected) uploaded \(uploaded) count \(renderer.lightDataUploadCount) lights \(renderer.uploadedLightData.count) live \(light.data.color)") }
            if simd_distance(simd_make_float3(uploaded.x, uploaded.y, uploaded.z), expected) > 1e-4 { stale += 1 }
        }
        XCTAssertEqual(stale, 0, "frames whose uploaded light color did not match the recorded light")
    }
}
