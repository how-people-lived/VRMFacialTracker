import Foundation
import Metal
import IOSurface
import OpenGL

// MARK: - Metal → Syphon bridge via IOSurface
//
// Syphon uses OpenGL (CGL) internally. We bridge Metal renders to Syphon by:
//   1. Allocating a shared IOSurface (accessible by both Metal and OpenGL)
//   2. Creating a Metal texture backed by that IOSurface
//   3. Creating a CGL context + OpenGL texture that reads the same IOSurface
//   4. After each Metal render (to the IOSurface texture), calling
//      SyphonServer.publishFrameTexture() — which Syphon clients (OBS) then read.
//
// Alpha channel is preserved: Metal renders with alpha, Syphon shares BGRA8.

final class SyphonBridge {

    let metalTexture: MTLTexture   // render to this from SceneRenderer
    private let ioSurface:   IOSurface
    private let cglContext:  CGLContextObj
    private var glTexture:   GLuint = 0
    private let server:      SyphonServer
    private let width:  Int
    private let height: Int

    // MARK: - Init

    init?(name: String = "VRM Avatar", device: MTLDevice,
          width: Int = 1280, height: Int = 720) {
        self.width  = width
        self.height = height

        // 1. IOSurface (BGRA8, shared CPU/GPU memory)
        guard let surface = IOSurface(properties: [
            .width:            width,
            .height:           height,
            .pixelFormat:      Int(kCVPixelFormatType_32BGRA),
            .bytesPerElement:  4,
            .bytesPerRow:      width * 4
        ] as [IOSurfacePropertyKey: Any]) else { return nil }
        ioSurface = surface

        // 2. Metal texture from IOSurface (.shared = accessible by both Metal and CPU)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width, height: height, mipmapped: false)
        desc.usage       = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc,
                                           iosurface: ioSurface as IOSurfaceRef, plane: 0)
        else { return nil }
        metalTexture = tex

        // 3. CGL headless context (no display needed)
        var pfAttribs: [CGLPixelFormatAttribute] = [
            CGLPixelFormatAttribute(kCGLPFAAccelerated.rawValue),
            CGLPixelFormatAttribute(kCGLPFAColorSize.rawValue),
            CGLPixelFormatAttribute(32),
            CGLPixelFormatAttribute(kCGLPFAAlphaSize.rawValue),
            CGLPixelFormatAttribute(8),
            CGLPixelFormatAttribute(0)
        ]
        var pf: CGLPixelFormatObj?
        var npf: GLint = 0
        guard CGLChoosePixelFormat(&pfAttribs, &pf, &npf) == kCGLNoError,
              let pixelFormat = pf else { return nil }

        var ctx: CGLContextObj?
        guard CGLCreateContext(pixelFormat, nil, &ctx) == kCGLNoError,
              let context = ctx else { return nil }
        cglContext = context
        CGLSetCurrentContext(cglContext)

        // 4. OpenGL texture bound to the IOSurface
        glGenTextures(1, &glTexture)
        glBindTexture(GLenum(GL_TEXTURE_RECTANGLE_EXT), glTexture)
        let result = CGLTexImageIOSurface2D(
            cglContext,
            GLenum(GL_TEXTURE_RECTANGLE_EXT),
            GLenum(GL_RGBA8),
            GLsizei(width), GLsizei(height),
            GLenum(GL_BGRA),
            GLenum(GL_UNSIGNED_INT_8_8_8_8_REV),
            ioSurface as IOSurfaceRef, 0)
        guard result == kCGLNoError else { return nil }

        // 5. Syphon server (holds a reference to the CGL context)
        guard let syphon = SyphonServer(name: name,
                                         context: cglContext,
                                         options: nil) else { return nil }
        server = syphon
    }

    // MARK: - Publish

    /// Call after each Metal render (commandBuffer must already be committed/completed).
    func publish() {
        CGLSetCurrentContext(cglContext)
        server.publishFrameTexture(
            glTexture,
            textureTarget:    GLenum(GL_TEXTURE_RECTANGLE_EXT),
            imageRegion:      NSRect(x: 0, y: 0, width: width, height: height),
            textureDimensions: NSSize(width: width, height: height),
            flipped:           false)
    }

    func stop() { server.stop() }
}
