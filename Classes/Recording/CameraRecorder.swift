//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

import AVFoundation
import Foundation
import UIKit
import VideoToolbox

/// Default values for the camera recorder
private struct CameraRecordingConstants {
    /// queue for exporting
    static let prepareQueue: String = "PrepareQueue"
}

/// An implementation of a CameraRecordingProtocol without filters

final class CameraRecorder: NSObject {
    weak var recordingDelegate: CameraRecordingDelegate?

    private var url: URL?
    private(set) var size: CGSize

    private var assetWriter: AVAssetWriter?
    private var assetWriterVideoInput: AVAssetWriterInput?
    private var assetWriterAudioInput: AVAssetWriterInput?
    private var assetWriterPixelBufferInput: AVAssetWriterInputPixelBufferAdaptor?

    private let photoOutput: AVCapturePhotoOutput?
    private let videoOutput: AVCaptureVideoDataOutput?
    private let audioOutput: AVCaptureAudioDataOutput?

    private var currentRecordingMode: CameraMode
    let segmentsHandler: SegmentsHandlerType

    private let photoOutputHandler: PhotoOutputHandler
    private let gifVideoOutputHandler: GifVideoOutputHandler
    private var videoOutputHandlers: [VideoOutputHandler]
    private var currentVideoOutputHandler: VideoOutputHandler? {
        return videoOutputHandlers.last
    }

    private var takingPhoto: Bool = false

    private let settings: CameraSettings
    
    required init(size: CGSize,
                  photoOutput: AVCapturePhotoOutput?,
                  videoOutput: AVCaptureVideoDataOutput?,
                  audioOutput: AVCaptureAudioDataOutput?,
                  recordingDelegate: CameraRecordingDelegate?,
                  segmentsHandler: SegmentsHandlerType,
                  settings: CameraSettings) {
        self.size = size

        photoOutputHandler = PhotoOutputHandler(photoOutput: photoOutput)
        gifVideoOutputHandler = GifVideoOutputHandler(videoOutput: videoOutput, usePixelBuffer: settings.features.openGLCapture)
        videoOutputHandlers = []

        self.photoOutput = photoOutput
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        self.recordingDelegate = recordingDelegate
        self.segmentsHandler = segmentsHandler
        self.settings = settings

        currentRecordingMode = settings.newCameraModes ? .stitch : .stopMotion

        super.init()

        setupNotifications()
    }

    /// This helper function sets up an asset writer at the url. If running on simulator or if devices are not available, it should return without setting up any further
    ///
    /// - Parameter url: the output url for the exported mp4
    private func setupAssetWriter(url: URL?) {
        guard let url = url, size.width != 0, size.height != 0 else { return }
        do {
            assetWriter = try AVAssetWriter(outputURL: url, fileType: AVFileType.mp4)
        } catch {
            NSLog("failed to setup asset writer")
            return
        }
        self.url = url

        let videoOutputSettings: [String: Any] = segmentsHandler.videoOutputSettingsForSize(size: size)
        let videoInput = AVAssetWriterInput(mediaType: AVMediaType.video, outputSettings: videoOutputSettings)
        videoInput.expectsMediaDataInRealTime = true
        
        let sourcePixelBufferAttributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height]

        assetWriterPixelBufferInput = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: sourcePixelBufferAttributes)
        if assetWriter?.canAdd(videoInput) == true {
            assetWriter?.add(videoInput)
        }

        assetWriterVideoInput = videoInput
        setupAudioForAssetWriter()
    }

    private func setupAudioForAssetWriter() {
        let sampleRate = AVAudioSession.sharedInstance().sampleRate
        guard sampleRate != 0 else {
            NSLog("should not setup up the audio asset writer if no sample rate found")
            return
        }
        var audioChannelLayout: AudioChannelLayout = AudioChannelLayout()
        memset(&audioChannelLayout, 0, MemoryLayout<AudioChannelLayout>.size)
        audioChannelLayout.mChannelLayoutTag = kAudioChannelLayoutTag_Mono
        let data = NSData(bytes: &audioChannelLayout, length: MemoryLayout<AudioChannelLayout>.size)

        let audioOutputSettings: [String: Any] = [AVFormatIDKey as String: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey as String: 1, AVSampleRateKey as String: sampleRate, AVEncoderBitRateKey as String: 64000, AVChannelLayoutKey as String: data]
        assetWriterAudioInput = AVAssetWriterInput(mediaType: AVMediaType.audio, outputSettings: audioOutputSettings)
        assetWriterAudioInput?.expectsMediaDataInRealTime = true
        if let audioInput = assetWriterAudioInput, assetWriter?.canAdd(audioInput) == true {
            assetWriter?.add(audioInput)
        }
    }

    private func setupNotifications() {
        let notificationCenter = NotificationCenter.default
        notificationCenter.addObserver(self, selector: #selector(appWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func appWillResignActive() {
        if isRecording() {
            switch currentRecordingMode {
            case .gif:
                cancelGif()
            case .stopMotion, .stitch:
                stopRecordingVideo(completion: { _ in })
            default:
                break
            }
        }
    }
    
    // MARK: - private gif creation logic

    private func cancelGif() {
        gifVideoOutputHandler.cancelGif()
    }
}

// MARK: - CameraRecordingProtocol

extension CameraRecorder: CameraRecordingProtocol {

    func addSegment(_ segment: CameraSegment) {
        segmentsHandler.addSegment(segment)
    }

    func updateOutputSize(_ size: CGSize) {
        guard !isRecording() else {
            return
        }
        self.size = size
    }

    func isRecording() -> Bool {
        switch currentRecordingMode {
        case .stopMotion, .stitch:
            if let handler = currentVideoOutputHandler {
                return handler.recording
            }
            else {
                return false
            }
        case .photo:
            return takingPhoto
        case .gif:
            return gifVideoOutputHandler.recording
        }
    }

    func segments() -> [CameraSegment] {
        return segmentsHandler.segments
    }

    func outputURL() -> URL? {
        return url
    }

    func cancelRecording() {
        if isRecording() {
            assetWriter?.cancelWriting()
        }
    }

    // MARK: - video
    func startRecordingVideo() {
        if isRecording() {
            return
        }

        let outputHandler = VideoOutputHandler()
        videoOutputHandlers.append(outputHandler)

        currentRecordingMode = settings.newCameraModes ? .stitch : .stopMotion
        recordingDelegate?.cameraWillTakeVideo()

        setupAssetWriter(url: NSURL.createNewVideoURL())
        guard let assetWriter = assetWriter, let pixelBufferAdaptor = assetWriterPixelBufferInput else {
            return
        }
        outputHandler.startRecordingVideo(assetWriter: assetWriter, pixelBufferAdaptor: pixelBufferAdaptor, audioInput: assetWriterAudioInput)
    }

    func stopRecordingVideo(completion: @escaping (URL?) -> Void) {
        if let videoOutputHandler = currentVideoOutputHandler {
            videoOutputHandler.stopRecordingVideo { [weak self] success in
                if let strongSelf = self {
                    strongSelf.recordingDelegate?.cameraWillFinishVideo()
                    strongSelf.removeVideoOutputHandler(videoOutputHandler)
                    if success, let url = videoOutputHandler.assetWriterURL() {
                        strongSelf.segmentsHandler.addNewVideoSegment(url: url)
                        completion(url)
                    }
                    else {
                        completion(nil)
                    }
                }
            }
        }
    }

    private func removeVideoOutputHandler(_ handler: VideoOutputHandler) {
        videoOutputHandlers = videoOutputHandlers.filter() { $0 != handler }
    }

    func takePhoto(cameraPosition: AVCaptureDevice.Position? = .back, completion: @escaping (UIImage?) -> Void) {
        guard isRecording() == false else {
            return
        }
        
        currentRecordingMode = .photo

        let settings = recordingDelegate?.photoSettings(for: photoOutput)
        takingPhoto = true
        photoOutputHandler.takePhoto(settings: settings ?? AVCapturePhotoSettings()) { [unowned self] image in
            self.takingPhoto = false
            guard var image = image else {
                completion(nil)
                return
            }
            if cameraPosition == .front, let flippedImage = image.flipLeftMirrored() {
                image = flippedImage
            }
            guard let filteredImage = self.recordingDelegate?.cameraDidTakePhoto(image: image) else {
                completion(nil)
                return
            }
            self.segmentsHandler.addNewImageSegment(image: filteredImage, size: self.size, completion: { (success, _) in
                completion(success ? filteredImage : nil)
            })
        }
    }

    func exportRecording(completion: @escaping (URL?) -> Void) {
        segmentsHandler.exportVideo(completion: { url in
            completion(url)
        })
    }

    func deleteSegment(at index: Int, removeFromDisk: Bool = true) {
        segmentsHandler.deleteSegment(at: index, removeFromDisk: removeFromDisk)
    }

    func moveSegment(from originIndex: Int, to destinationIndex: Int) {
        segmentsHandler.moveSegment(from: originIndex, to: destinationIndex)
    }

    // MARK: - gif
    func takeGifMovie(useLongerDuration: Bool = false, completion: @escaping (URL?) -> Void) {
        if isRecording() {
            completion(nil)
            return
        }
        currentRecordingMode = .gif
        recordingDelegate?.cameraWillTakeVideo()

        setupAssetWriter(url: NSURL.createNewVideoURL())

        gifVideoOutputHandler.takeGifMovie(assetWriter: assetWriter, pixelBufferAdaptor: assetWriterPixelBufferInput, videoInput: assetWriterVideoInput, audioInput: assetWriterAudioInput, longerDuration: useLongerDuration) { [unowned self] success in
            self.recordingDelegate?.cameraWillFinishVideo()
            completion(success ? self.url : nil)
        }
    }

    func processVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        switch currentRecordingMode {
        case .stopMotion, .stitch:
            currentVideoOutputHandler?.processVideoSampleBuffer(sampleBuffer)
        case .gif:
            gifVideoOutputHandler.processVideoSampleBuffer(sampleBuffer)
        default: break
        }
    }

    func processVideoPixelBuffer(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        switch currentRecordingMode {
        case .stopMotion, .stitch:
            currentVideoOutputHandler?.processVideoPixelBuffer(pixelBuffer, presentationTime: presentationTime)
        case .gif:
            gifVideoOutputHandler.processVideoPixelBuffer(pixelBuffer)
        default: break
        }
    }

    func processAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        switch currentRecordingMode {
        case .stopMotion, .stitch:
            currentVideoOutputHandler?.processAudioSampleBuffer(sampleBuffer)
        default: break
        }
    }

    func reset() {
        setupAssetWriter(url: NSURL.createNewVideoURL())
        segmentsHandler.reset(removeFromDisk: true)
    }

    func currentClipDuration() -> TimeInterval? {
        guard currentRecordingMode == .stopMotion || currentRecordingMode == .stitch else {
            return nil
        }
        return currentVideoOutputHandler?.currentClipDuration()
    }
}
