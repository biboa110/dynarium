// SPDX-License-Identifier: GPL-2.0-or-later

import AVFAudio
import AVFoundation
import AVKit
import Combine
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UIKit

private nonisolated struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

private nonisolated struct SendableLayerBox: @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer
}

private nonisolated final class PiPFrameConsumer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.dynarium.pip.sample-enqueue", qos: .userInteractive)
    private let layerBox: SendableLayerBox
    private let hostClock = CMClockGetHostTimeClock()

    init(layer: AVSampleBufferDisplayLayer) {
        self.layerBox = SendableLayerBox(layer: layer)
    }

    func receive(pixelBuffer: CVPixelBuffer) {
        let box = SendablePixelBuffer(buffer: pixelBuffer)
        let targetLayer = layerBox
        queue.async { [targetLayer, hostClock, box] in
            let layer = targetLayer.layer
            var formatDescription: CMVideoFormatDescription?
            let fmtStatus = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: box.buffer,
                formatDescriptionOut: &formatDescription
            )
            guard fmtStatus == noErr, let format = formatDescription else { return }

            let now = CMClockGetTime(hostClock)
            var timing = CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 30),
                presentationTimeStamp: now,
                decodeTimeStamp: .invalid
            )

            var sampleBuffer: CMSampleBuffer?
            let sampleStatus = CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: box.buffer,
                formatDescription: format,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            )
            guard sampleStatus == noErr, let sample = sampleBuffer else { return }

            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    dict,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }

            if #available(iOS 17.0, *) {
                let renderer = layer.sampleBufferRenderer
                if renderer.status == .failed { renderer.flush() }
                if renderer.isReadyForMoreMediaData {
                    renderer.enqueue(sample)
                }
            } else {
                if layer.status == .failed { layer.flush() }
                if layer.isReadyForMoreMediaData {
                    layer.enqueue(sample)
                }
            }
        }
    }
}

final class PiPHostLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { unsafeDowncast(layer, to: AVSampleBufferDisplayLayer.self) }
}

struct PiPHostViewRepresentable: UIViewRepresentable {
    @ObservedObject var controller: DynariumPiPController

    func makeUIView(context: Context) -> PiPHostLayerView {
        let view = controller.hostLayerView
        view.displayLayer.videoGravity = .resizeAspect
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        controller.configureIfNeeded()
        return view
    }

    func updateUIView(_ uiView: PiPHostLayerView, context: Context) {}
}

@MainActor
final class DynariumPiPController: NSObject, ObservableObject {
    @Published private(set) var isSupported: Bool = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var isActive: Bool = false

    let hostLayerView = PiPHostLayerView(frame: CGRect(x: 0, y: 0, width: 16, height: 16))

    private var pipController: AVPictureInPictureController?
    private var frameConsumer: PiPFrameConsumer?
    private var sinkInstalled = false
    private var consumerRetainBox: Unmanaged<PiPFrameConsumer>?
    private var onStateChanged: ((Bool) -> Void)?

    func setStateHandler(_ handler: @escaping (Bool) -> Void) {
        onStateChanged = handler
    }

    func configureIfNeeded() {
        guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: hostLayerView.displayLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: contentSource)
        pip.delegate = self
        pip.canStartPictureInPictureAutomaticallyFromInline = false
        pipController = pip
        frameConsumer = PiPFrameConsumer(layer: hostLayerView.displayLayer)
    }

    func toggle(fps: Int) {
        configureIfNeeded()
        guard let pip = pipController else { return }
        if pip.isPictureInPictureActive {
            stop()
        } else {
            start(fps: fps)
        }
    }

    func start(fps: Int) {
        configureIfNeeded()
        guard let pip = pipController, !pip.isPictureInPictureActive else { return }
        activateAudioSession()
        installFrameSink(fps: fps)
        pip.startPictureInPicture()
    }

    func stop() {
        if let pip = pipController, pip.isPictureInPictureActive {
            pip.stopPictureInPicture()
        }
        removeFrameSink()
    }

    func updateAutoStartFromInline(_ autoStart: Bool, fps: Int) {
        configureIfNeeded()
        pipController?.canStartPictureInPictureAutomaticallyFromInline = autoStart
        if autoStart {
            activateAudioSession()
            installFrameSink(fps: fps)
        } else if !isActive {
            removeFrameSink()
        }
    }

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    private static let frameSinkCallback: kernarium_runtime_frame_sink = { context, pixelBuffer in
        guard let context, let pixelBuffer else { return }
        let consumer = Unmanaged<PiPFrameConsumer>.fromOpaque(context).takeUnretainedValue()
        let cvBuffer = Unmanaged<CVPixelBuffer>.fromOpaque(pixelBuffer).takeUnretainedValue()
        consumer.receive(pixelBuffer: cvBuffer)
    }

    private func installFrameSink(fps: Int) {
        guard let consumer = frameConsumer else { return }
        removeFrameSink()
        let retained = Unmanaged.passRetained(consumer)
        consumerRetainBox = retained
        let clampedFPS = UInt32(max(1, min(30, fps)))
        let rc = kernarium_runtime_loader_set_frame_sink(Self.frameSinkCallback, retained.toOpaque(), 720, clampedFPS)
        if rc == 0 {
            sinkInstalled = true
        } else {
            consumerRetainBox?.release()
            consumerRetainBox = nil
        }
    }

    func removeFrameSink() {
        if sinkInstalled {
            // Synchronous runtime guarantee: no callback executes after nil sink returns.
            _ = kernarium_runtime_loader_set_frame_sink(nil, nil, 0, 0)
            sinkInstalled = false
        }
        consumerRetainBox?.release()
        consumerRetainBox = nil
    }
}

extension DynariumPiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.isActive = true
            self?.onStateChanged?(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor [weak self] in
            self?.isActive = false
            self?.removeFrameSink()
            self?.onStateChanged?(false)
        }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor [weak self] in
            self?.isActive = false
            self?.removeFrameSink()
            self?.onStateChanged?(false)
        }
    }
}

extension DynariumPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        setPlaying playing: Bool
    ) {
        // Guest video mirrors live framebuffer continuously without pause scrubbing.
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {}

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
