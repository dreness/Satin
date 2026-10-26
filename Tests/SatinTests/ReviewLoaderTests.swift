@testable import Satin
import Metal
import MetalKit
import ModelIO
import simd
import XCTest

/// Review repros: OBJ cull mode, USDA doubleSided cull mode, and sharing of identical but
/// separately named materials. Compiles against base and PR.
final class ReviewLoaderTests: XCTestCase {
    private var context: Context!
    private var textureLoader: MTKTextureLoader!
    private var directory: URL!

    override func setUpWithError() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm, depthPixelFormat: .depth32Float)
        textureLoader = MTKTextureLoader(device: device)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReviewLoader-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let mtl = """
    newmtl RedA
    Kd 1.0 0.0 0.0
    Ka 0.0 0.0 0.0
    Ks 0.0 0.0 0.0
    Ns 10.0
    d 1.0
    illum 2

    newmtl RedB
    Kd 1.0 0.0 0.0
    Ka 0.0 0.0 0.0
    Ks 0.0 0.0 0.0
    Ns 10.0
    d 1.0
    illum 2

    """

    private let obj = """
    mtllib two.mtl
    v 0 0 0
    v 1 0 0
    v 0 1 0
    v 2 0 0
    v 3 0 0
    v 2 1 0
    o A
    usemtl RedA
    f 1 2 3
    o B
    usemtl RedB
    f 4 5 6

    """

    private let usda = """
    #usda 1.0
    (
        defaultPrim = "Root"
        upAxis = "Y"
    )
    def Xform "Root"
    {
        def Material "Mat"
        {
            token outputs:surface.connect = </Root/Mat/Surface.outputs:surface>
            def Shader "Surface"
            {
                uniform token info:id = "UsdPreviewSurface"
                color3f inputs:diffuseColor = (1, 0, 0)
                token outputs:surface
            }
        }
        def Mesh "Single" (prepend apiSchemas = ["MaterialBindingAPI"])
        {
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
            rel material:binding = </Root/Mat>
        }
        def Mesh "Double" (prepend apiSchemas = ["MaterialBindingAPI"])
        {
            uniform bool doubleSided = 1
            int[] faceVertexCounts = [3]
            int[] faceVertexIndices = [0, 1, 2]
            point3f[] points = [(2, 0, 0), (3, 0, 0), (2, 1, 0)]
            rel material:binding = </Root/Mat>
        }
    }

    """

    private func meshes(in model: Object) -> [Mesh] {
        model.getChildren().compactMap { $0 as? Mesh }
    }

    private func loadOBJ() throws -> [Mesh] {
        try mtl.write(to: directory.appendingPathComponent("two.mtl"), atomically: true, encoding: .utf8)
        let url = directory.appendingPathComponent("two.obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        let asset = MDLAsset(url: url)
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
                print("REVIEW OBJ ModelIO mesh \(mesh.name) submesh material=\(submesh.material?.name ?? "nil") materialFace=\(submesh.material?.materialFace.rawValue ?? 99)")
            }
        }
        let model = try XCTUnwrap(loadAsset(url: url, context: context, textureLoader: textureLoader))
        return meshes(in: model)
    }

    func testOBJCullMode() throws {
        let meshes = try loadOBJ()
        XCTAssertFalse(meshes.isEmpty)
        for mesh in meshes {
            print("REVIEW OBJ mesh \(mesh.label) cullMode=\(mesh.cullMode.rawValue) (0 none, 1 front, 2 back)")
        }
        for mesh in meshes {
            XCTAssertEqual(mesh.cullMode, .none, "OBJ mesh \(mesh.label) is culled")
        }
    }

    func testUSDADoubleSidedCullMode() throws {
        let url = directory.appendingPathComponent("sided.usda")
        try usda.write(to: url, atomically: true, encoding: .utf8)
        let asset = MDLAsset(url: url)
        for case let mesh as MDLMesh in asset.childObjects(of: MDLMesh.self) {
            for case let submesh as MDLSubmesh in mesh.submeshes ?? [] {
                print("REVIEW USDA ModelIO mesh \(mesh.name) materialFace=\(submesh.material?.materialFace.rawValue ?? 99)")
            }
        }
        let model = try XCTUnwrap(loadAsset(url: url, context: context, textureLoader: textureLoader))
        for mesh in meshes(in: model) {
            print("REVIEW USDA mesh \(mesh.label) cullMode=\(mesh.cullMode.rawValue)")
        }
    }

    func testIdenticalSeparatelyNamedMaterialsAreShared() throws {
        let meshes = try loadOBJ()
        let mesh = try XCTUnwrap(meshes.first)
        XCTAssertEqual(mesh.submeshes.count, 2)
        let materialA = try XCTUnwrap(mesh.submeshes.first?.material as? StandardMaterial)
        let materialB = try XCTUnwrap(mesh.submeshes.last?.material as? StandardMaterial)
        let shared = materialA === materialB
        let before = materialB.baseColor
        materialA.baseColor = [0, 0, 1, 1]
        print("REVIEW OBJ submesh material RedA===RedB: \(shared); RedB.baseColor before=\(before) after editing RedA=\(materialB.baseColor)")
        XCTAssertFalse(shared, "RedA and RedB share one material")
        XCTAssertEqual(materialB.baseColor, before, "editing RedA's material changed RedB's")
    }

    func testIdenticalSeparatelyNamedUSDMaterialsAreShared() throws {
        let source = """
        #usda 1.0
        (
            defaultPrim = "Root"
            upAxis = "Y"
        )
        def Xform "Root"
        {
            def Material "RedA"
            {
                token outputs:surface.connect = </Root/RedA/Surface.outputs:surface>
                def Shader "Surface"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (1, 0, 0)
                    token outputs:surface
                }
            }
            def Material "RedB"
            {
                token outputs:surface.connect = </Root/RedB/Surface.outputs:surface>
                def Shader "Surface"
                {
                    uniform token info:id = "UsdPreviewSurface"
                    color3f inputs:diffuseColor = (1, 0, 0)
                    token outputs:surface
                }
            }
            def Mesh "A" (prepend apiSchemas = ["MaterialBindingAPI"])
            {
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                point3f[] points = [(0, 0, 0), (1, 0, 0), (0, 1, 0)]
                rel material:binding = </Root/RedA>
            }
            def Mesh "B" (prepend apiSchemas = ["MaterialBindingAPI"])
            {
                int[] faceVertexCounts = [3]
                int[] faceVertexIndices = [0, 1, 2]
                point3f[] points = [(2, 0, 0), (3, 0, 0), (2, 1, 0)]
                rel material:binding = </Root/RedB>
            }
        }

        """
        let url = directory.appendingPathComponent("twins.usda")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let model = try XCTUnwrap(loadAsset(url: url, context: context, textureLoader: textureLoader))
        let loaded = meshes(in: model)
        let a = try XCTUnwrap(loaded.first { $0.label == "A" }, "labels \(loaded.map(\.label))")
        let b = try XCTUnwrap(loaded.first { $0.label == "B" }, "labels \(loaded.map(\.label))")
        let materialA = try XCTUnwrap(a.material as? StandardMaterial)
        let materialB = try XCTUnwrap(b.material as? StandardMaterial)
        let shared = materialA === materialB
        let before = materialB.baseColor
        materialA.baseColor = [0, 0, 1, 1]
        print("REVIEW USDA mesh material A===B: \(shared); B.baseColor before=\(before) after editing A=\(materialB.baseColor)")
        XCTAssertFalse(shared, "RedA and RedB share one material")
        XCTAssertEqual(materialB.baseColor, before, "editing A's material changed B's")
    }
}
