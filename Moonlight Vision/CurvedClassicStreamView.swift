//
//  CurvedClassicStreamView.swift
//  Moonlight Vision
//
//  Classic streaming pipeline (DrawableVideoDecoder) displayed on a curved
//  RealityKit mesh inside a standard volumetric window. No immersive space —
//  other apps can be used alongside it.
//

import SwiftUI
import RealityKit

struct CurvedClassicStreamView: View {
    @Binding var streamConfig: StreamConfiguration?

    @EnvironmentObject private var viewModel: MainViewModel
    @Environment(\.dismissWindow) private var dismissWindow

    @ObservedObject private var connectionCallbacks = ObservableConnectionManager()

    @State private var streamMan: StreamManager?
    @State private var texture: TextureResource = CurvedClassicStreamView.makePlaceholderTexture()
    @State private var screen: ModelEntity = ModelEntity()
    @State private var curvature: Float = 0.3

    @State private var hasPerformedTeardown = false
    @State private var firstFrameReceived = false
    @State private var renderGateOpen = false
    @State private var idrWatchdog1: Timer?
    @State private var idrWatchdog2: Timer?

    private var screenAspect: Float {
        guard let cfg = streamConfig else { return 9.0 / 16.0 }
        return Float(cfg.height) / Float(cfg.width)
    }

    var body: some View {
        RealityView { content in
            let entity = makeScreenEntity(curvature: curvature)
            screen = entity
            content.add(entity)
        } update: { content in
            updateCurvature(curvature)
        }
        .ornament(attachmentAnchor: .scene(.bottom)) {
            sliderBar
        }
        .onAppear {
            curvature = viewModel.streamSettings.classicCurvedCurvature
            startStream()
        }
        .onDisappear {
            teardown()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("RequestStreamCloseFromMainMenu"))) { _ in
            teardown()
            dismissWindow(id: "classicCurvedStreamingWindow")
        }
        .onReceive(connectionCallbacks.$connectionStatus) { status in
            if status == "Failed" || status == "Terminated" {
                teardown()
            }
        }
    }

    // MARK: - Slider ornament

    private var sliderBar: some View {
        HStack(spacing: 16) {
            Image(systemName: "arrow.left.and.right")
                .foregroundStyle(.secondary)
                .font(.caption)
            Slider(value: $curvature, in: 0...1, step: 0.001)
                .frame(width: 220)
                .onChange(of: curvature) { _, newVal in
                    updateCurvature(newVal)
                    viewModel.streamSettings.classicCurvedCurvature = newVal
                    viewModel.streamSettings.save()
                }
            Image(systemName: "arrow.left.and.right.circle")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .glassBackgroundEffect()
    }

    // MARK: - RealityKit helpers

    private func makeScreenEntity(curvature: Float) -> ModelEntity {
        let mesh = (try? generateCurvedRoundedPlane(
            width: 2.0,
            aspectRatio: screenAspect,
            resolution: (256, 256),
            curveMagnitude: curvature,
            cornerRadiusFraction: 0.02
        )) ?? MeshResource.generatePlane(width: 2.0, height: 2.0 * screenAspect)

        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(texture: .init(texture))

        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = SIMD3<Float>(0, 0, -1.5)
        return entity
    }

    private func updateCurvature(_ value: Float) {
        guard let mesh = try? generateCurvedRoundedPlane(
            width: 2.0,
            aspectRatio: screenAspect,
            resolution: (256, 256),
            curveMagnitude: value,
            cornerRadiusFraction: 0.02
        ) else { return }
        screen.model?.mesh = mesh
    }

    private static func makePlaceholderTexture() -> TextureResource {
        let w = 1920, h = 1080
        let data = Data(count: 4 * w * h)
        return try! TextureResource(
            dimensions: .dimensions(width: w, height: h),
            format: .raw(pixelFormat: .bgra8Unorm_srgb),
            contents: .init(mipmapLevels: [.mip(data: data, bytesPerRow: 4 * w)])
        )
    }

    // MARK: - Stream lifecycle

    private func startStream() {
        guard streamMan == nil, let cfg = streamConfig, viewModel.activelyStreaming else { return }

        // Create texture sized to stream resolution
        let w = Int(cfg.width), h = Int(cfg.height)
        let data = Data(count: 4 * w * h)
        if let tex = try? TextureResource(
            dimensions: .dimensions(width: w, height: h),
            format: .raw(pixelFormat: .bgra8Unorm_srgb),
            contents: .init(mipmapLevels: [.mip(data: data, bytesPerRow: 4 * w)])
        ) {
            texture = tex
            // Rebind material with correct-size texture
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(texture: .init(tex))
            screen.model?.materials = [material]
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard !hasPerformedTeardown, viewModel.activelyStreaming, streamMan == nil else { return }

            renderGateOpen = true
            firstFrameReceived = false

            idrWatchdog1 = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                if !firstFrameReceived { LiRequestIdrFrame() }
            }
            idrWatchdog2 = Timer.scheduledTimer(withTimeInterval: 0.9, repeats: false) { _ in
                if !firstFrameReceived { LiRequestIdrFrame() }
            }

            let localTexture = texture

            streamMan = StreamManager(
                config: cfg,
                rendererProvider: {
                    DrawableVideoDecoder(
                        texture: localTexture,
                        callbacks: connectionCallbacks,
                        aspectRatio: screenAspect,
                        useFramePacing: cfg.useFramePacing,
                        enableHDR: false,
                        hdrSettingsProvider: nil,
                        enhancementsProvider: { (1.0, 1.0, 0.0) },
                        callbackToRender: { textureQueue, _ in
                            guard renderGateOpen else { return }
                            DispatchQueue.main.async {
                                texture.replace(withDrawables: textureQueue)
                                if !firstFrameReceived {
                                    firstFrameReceived = true
                                    idrWatchdog1?.invalidate(); idrWatchdog1 = nil
                                    idrWatchdog2?.invalidate(); idrWatchdog2 = nil
                                }
                            }
                        }
                    )
                },
                connectionCallbacks: connectionCallbacks
            )

            let queue = OperationQueue()
            queue.qualityOfService = .userInteractive
            if let sm = streamMan {
                queue.addOperation(sm)
            }
        }
    }

    private func teardown() {
        guard !hasPerformedTeardown else { return }
        hasPerformedTeardown = true
        renderGateOpen = false

        idrWatchdog1?.invalidate(); idrWatchdog1 = nil
        idrWatchdog2?.invalidate(); idrWatchdog2 = nil

        var posted = false
        let postTeardown = {
            guard !posted else { return }
            posted = true
            NotificationCenter.default.post(name: Notification.Name("RKStreamDidTeardown"), object: nil)
        }

        if let sm = streamMan {
            streamMan = nil
            sm.stopStream {
                DispatchQueue.main.async { postTeardown() }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { postTeardown() }
        } else {
            postTeardown()
        }
    }

    // MARK: - Curved mesh generation (from RealityKitStreamView)

    private func generateCurvedRoundedPlane(
        width: Float,
        aspectRatio: Float,
        resolution: (UInt32, UInt32),
        curveMagnitude: Float,
        cornerRadiusFraction: Float
    ) throws -> MeshResource {
        var descr = MeshDescriptor(name: "curved_rounded_plane")
        let height = width * aspectRatio
        let vertexCount = Int(resolution.0 * resolution.1)
        let numQuadsX = resolution.0 - 1
        let numQuadsY = resolution.1 - 1
        let triangleCount = Int(numQuadsX * numQuadsY * 2)
        let indexCount = triangleCount * 3

        var positions = [SIMD3<Float>](repeating: .zero, count: vertexCount)
        var texcoords = [SIMD2<Float>](repeating: .zero, count: vertexCount)
        var indices = [UInt32](repeating: 0, count: indexCount)

        let maxCurveAngle: Float = 1.3
        let currentAngle = maxCurveAngle * max(0.0, min(curveMagnitude, 2.0))
        let halfAngle = currentAngle / 2.0
        let isFlat = currentAngle < 0.0001
        let radius: Float = isFlat ? .infinity : (width / currentAngle)

        let cornerRadius = max(0.0, min(0.25, cornerRadiusFraction)) * height
        let x0 = -width / 2.0
        let y0 = -height / 2.0
        let texInset: Float = 0.002

        var vi = 0
        var ii = 0

        for y_v in 0 ..< resolution.1 {
            let v_geo = Float(y_v) / Float(resolution.1 - 1)
            let yFlat = (0.5 - v_geo) * height
            let v_tex = (1.0 - v_geo) * (1.0 - 2.0 * texInset) + texInset

            for x_v in 0 ..< resolution.0 {
                let u = Float(x_v) / Float(resolution.0 - 1)
                let xFlat = (u - 0.5) * width

                var xr = xFlat, yr = yFlat
                if cornerRadius > 0 {
                    if xr < x0 + cornerRadius && yr < y0 + cornerRadius {
                        let dx = xr - (x0 + cornerRadius), dy = yr - (y0 + cornerRadius)
                        if let (nx, ny) = curveHelperNormalize(dx, dy, cornerRadius) { xr = (x0 + cornerRadius) + nx; yr = (y0 + cornerRadius) + ny }
                    } else if xr > -x0 - cornerRadius && yr < y0 + cornerRadius {
                        let dx = xr - (-x0 - cornerRadius), dy = yr - (y0 + cornerRadius)
                        if let (nx, ny) = curveHelperNormalize(dx, dy, cornerRadius) { xr = (-x0 - cornerRadius) + nx; yr = (y0 + cornerRadius) + ny }
                    } else if xr < x0 + cornerRadius && yr > -y0 - cornerRadius {
                        let dx = xr - (x0 + cornerRadius), dy = yr - (-y0 - cornerRadius)
                        if let (nx, ny) = curveHelperNormalize(dx, dy, cornerRadius) { xr = (x0 + cornerRadius) + nx; yr = (-y0 - cornerRadius) + ny }
                    } else if xr > -x0 - cornerRadius && yr > -y0 - cornerRadius {
                        let dx = xr - (-x0 - cornerRadius), dy = yr - (-y0 - cornerRadius)
                        if let (nx, ny) = curveHelperNormalize(dx, dy, cornerRadius) { xr = (-x0 - cornerRadius) + nx; yr = (-y0 - cornerRadius) + ny }
                    }
                }

                var px = xr, pz: Float = 0.0
                if !isFlat, radius.isFinite {
                    let t = xr / (width / 2.0)
                    let theta = t * halfAngle
                    px = radius * sin(theta)
                    pz = radius - (radius * cos(theta))
                }

                positions[vi] = SIMD3<Float>(px, yr, pz)
                let u_tex = u * (1.0 - 2.0 * texInset) + texInset
                texcoords[vi] = SIMD2<Float>(u_tex, v_tex)

                if x_v < numQuadsX && y_v < numQuadsY {
                    let current = UInt32(vi), nextRow = current + resolution.0
                    indices[ii + 0] = current; indices[ii + 1] = nextRow; indices[ii + 2] = nextRow + 1
                    indices[ii + 3] = current; indices[ii + 4] = nextRow + 1; indices[ii + 5] = current + 1
                    ii += 6
                }
                vi += 1
            }
        }

        descr.positions = MeshBuffer(positions)
        descr.textureCoordinates = MeshBuffers.TextureCoordinates(texcoords)
        descr.primitives = .triangles(indices)
        return try MeshResource.generate(from: [descr])
    }

    private func curveHelperNormalize(_ dx: Float, _ dy: Float, _ cornerRadius: Float) -> (Float, Float)? {
        let dist = sqrt(dx * dx + dy * dy)
        if dist > cornerRadius {
            let s = cornerRadius / dist
            return (dx * s, dy * s)
        }
        return nil
    }
}
