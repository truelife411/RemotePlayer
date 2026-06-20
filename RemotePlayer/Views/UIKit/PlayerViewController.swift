//
//  PlayerViewController.swift
//  RemotePlayer
//
//  UIKit 视频播放器主控制器。
//  职责：
//  1. 承载 VLCKit 渲染视图（通过 drawable）
//  2. 实现 VLCMediaPlayerDelegate，上报状态/时间/轨道变化
//  3. 容纳控制层（PlayerControlOverlay）与手势系统（GestureManager）
//  4. 提供播放/暂停/跳转/倍速/单帧/字幕切换/截图等接口
//
//  通过 UIViewControllerRepresentable 桥接到 SwiftUI（见 PlayerContainerView）。
//

import UIKit
import MobileVLCKit
import os

/// 播放器诊断日志（Console.app 用 subsystem=RemotePlayer, category=Player 过滤）。
private let playerLog = Logger(subsystem: "RemotePlayer", category: "Player")

/// 播放器对外回调（通知 SwiftUI 层状态变化）。
protocol PlayerViewControllerDelegate: AnyObject {
    func player(_ player: PlayerViewController, didChangeState state: VLCMediaPlayerState)
    func player(_ player: PlayerViewController, didChangeTime seconds: TimeInterval, duration: TimeInterval)
    func player(_ player: PlayerViewController, didChangePlaying isPlaying: Bool)
    func player(_ player: PlayerViewController, didDiscoverTextTracks tracks: [SubtitleTrack])
    func player(_ player: PlayerViewController, didEncounterError message: String)
}

final class PlayerViewController: UIViewController {

    // MARK: - 依赖

    /// 播放地址（本地代理 URL）。
    let streamURL: URL
    /// 断点续播起始秒数。
    let startPosition: TimeInterval
    /// 外挂字幕本地路径（已下载到本地）。nil 表示无外挂。
    let externalSubtitleURL: URL?

    weak var delegate: PlayerViewControllerDelegate?

    // MARK: - VLCKit

    private(set) var mediaPlayer: VLCMediaPlayer!
    /// VLCKit 渲染的宿主 UIView。
    private let videoContainerView = UIView()

    // MARK: - 子组件

    private(set) lazy var overlay = PlayerControlOverlay()
    private(set) lazy var gestureManager = GestureManager()

    // MARK: - 状态

    private var duration: TimeInterval = 0
    private var didApplyStartPosition = false
    private var progressSaveTimer: Timer?

    /// 缓冲指示防抖：VLCKit 在 HTTP 流播放期间会反复在 buffering/playing 间抖动，
    /// 直接跟随状态会让转圈频繁闪现。只在持续 buffering 超过阈值后才显示。
    private var bufferingShowWork: DispatchWorkItem?
    private let bufferingShowDelay: TimeInterval = 0.6

    // MARK: - 初始化

    init(streamURL: URL,
         startPosition: TimeInterval = 0,
         externalSubtitleURL: URL? = nil) {
        self.streamURL = streamURL
        self.startPosition = startPosition
        self.externalSubtitleURL = externalSubtitleURL
        super.init(nibName: nil, bundle: nil)
        setupPlayer()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupViews()
        setupGestures()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 进入全屏沉浸式
        navigationController?.setNavigationBarHidden(true, animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startPlayback()
        startProgressSaving()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveProgress()
        progressSaveTimer?.invalidate()
        mediaPlayer.stop()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .all }

    // MARK: - 视图布局

    private func setupViews() {
        // 视频容器：填满，等比缩放由 VLCKit 处理
        videoContainerView.backgroundColor = .black
        videoContainerView.translatesAutoresizingMaskIntoConstraints = false
        videoContainerView.clipsToBounds = true
        view.addSubview(videoContainerView)

        // 控制层覆盖在上
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        overlay.delegate = self

        NSLayoutConstraint.activate([
            videoContainerView.topAnchor.constraint(equalTo: view.topAnchor),
            videoContainerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            videoContainerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            videoContainerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - 播放器初始化

    private func setupPlayer() {
        // 使用默认共享库，并设置一些有利于流播放的选项
        // 网络缓存设大些：本地 HTTP 代理 → SMB 的读取延迟比直连文件高，
        // 缓存太小会导致播放中频繁 buffering 抖动（转圈闪烁）。
        let options: [String] = [
            "--network-caching=3000",        // 网络缓存 3s
            "--file-caching=2000",
            "--clock-jitter=0",
            "--rtsp-tcp",
            "--rtsp-caching=3000",
            "--http-caching=3000"
        ]
        mediaPlayer = VLCMediaPlayer(options: options)
        mediaPlayer.delegate = self
        mediaPlayer.drawable = videoContainerView
    }

    private func startPlayback() {
        let media = VLCMedia(url: streamURL)
        mediaPlayer.media = media

        // 外挂字幕
        if let externalSubtitleURL {
            _ = mediaPlayer.addPlaybackSlave(externalSubtitleURL,
                                             type: .subtitle,
                                             enforce: false)
        }
        mediaPlayer.play()
    }

    // MARK: - 手势

    private func setupGestures() {
        gestureManager.attach(to: view, player: self)
        gestureManager.delegate = self
    }

    // MARK: - 进度持久化（断点续播）

    /// 由外部设置，用于保存进度。
    var progressSaver: ((TimeInterval, TimeInterval, Float) -> Void)?
    var progressClearer: (() -> Void)?

    private func startProgressSaving() {
        progressSaveTimer = Timer(timeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.saveProgress()
        }
        // 加入 .common mode，滚动/拖动时也能触发
        RunLoop.main.add(progressSaveTimer!, forMode: .common)
    }

    private func saveProgress() {
        guard duration > 0 else { return }
        let pos = Double(mediaPlayer.time.intValue) / 1000.0
        progressSaver?(pos, duration, mediaPlayer.rate)
    }
}

// MARK: - VLCMediaPlayerDelegate

extension PlayerViewController: VLCMediaPlayerDelegate {

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let state = mediaPlayer.state
        playerLog.debug("VLC state -> \(state.rawValue) seekable=\(self.mediaPlayer.isSeekable) time=\(self.mediaPlayer.time.intValue) len=\(self.mediaPlayer.media?.length.intValue ?? -1)")
        delegate?.player(self, didChangeState: state)

        switch state {
        case .playing:
            delegate?.player(self, didChangePlaying: true)
            overlay.updatePlaying(true)
            cancelBufferingIndicator()
            // 起播后才应用断点续播位置，避免在 opening 阶段 seek 无效
            if !didApplyStartPosition, startPosition > 0 {
                didApplyStartPosition = true
                mediaPlayer.time = VLCTime(int: Int32(startPosition * 1000))
            }

        case .paused, .stopped:
            delegate?.player(self, didChangePlaying: false)
            overlay.updatePlaying(false)

        case .error:
            delegate?.player(self, didEncounterError: "播放出错，请检查网络或文件格式")
            cancelBufferingIndicator()

        case .buffering:
            // 防抖：仅当持续 buffering 超过阈值才显示转圈，
            // 避免 VLCKit 在流播放中的频繁瞬时 buffering 闪烁。
            scheduleBufferingIndicator()

        case .opening:
            scheduleBufferingIndicator()

        case .esAdded:
            // 轨道添加（字幕/音轨），上报字幕列表
            // VLCKit 的轨道加载是异步的，延迟一点再上报确保列表完整
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.reportTextTracks()
            }
        @unknown default:
            break
        }

        // ended 明确隐藏缓冲指示
        if state == .ended {
            cancelBufferingIndicator()
        }
    }

    // MARK: - 缓冲指示防抖

    private func scheduleBufferingIndicator() {
        // 已有挂起的显示任务，或已经在转圈，则不重复安排
        if bufferingShowWork != nil { return }
        let work = DispatchWorkItem { [weak self] in
            self?.overlay.updateBuffering(true)
        }
        bufferingShowWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + bufferingShowDelay, execute: work)
    }

    private func cancelBufferingIndicator() {
        bufferingShowWork?.cancel()
        bufferingShowWork = nil
        overlay.updateBuffering(false)
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        let currentMs = mediaPlayer.time.intValue
        let position = TimeInterval(currentMs) / 1000.0
        // 时长可能在播放后才可用
        let durMs = mediaPlayer.media?.length.intValue ?? 0
        if durMs > 0 {
            duration = TimeInterval(durMs) / 1000.0
        }
        // 时间在前进 = 确实在播放（哪怕 VLC 状态还停在 buffering），
        // 此时转圈毫无意义，强制隐藏。
        cancelBufferingIndicator()
        delegate?.player(self, didChangeTime: position, duration: duration)
        overlay.updateTime(current: position, duration: duration)
    }

    private func reportTextTracks() {
        // VLCKit 3.x：videoSubTitlesNames 返回字幕轨道名数组（[name]）。
        // currentVideoSubTitleIndex 为当前选中索引。
        let names = mediaPlayer.videoSubTitlesNames as? [String] ?? []
        let tracks = names.enumerated().map { (idx, name) in
            SubtitleTrack(id: Int32(idx),
                          name: name.isEmpty ? "字幕 \(idx + 1)" : name,
                          isExternal: false)
        }
        delegate?.player(self, didDiscoverTextTracks: tracks)
        overlay.updateSubtitleTracks(tracks)
    }
}

// MARK: - 对外播放控制接口（供 overlay / gesture 调用）

extension PlayerViewController {

    func togglePlayPause() {
        if mediaPlayer.isPlaying {
            mediaPlayer.pause()
        } else {
            mediaPlayer.play()
        }
    }

    /// 跳转到指定秒数（用于拖动进度条）。
    /// 对于 HTTP 流，time setter 偶尔无效（尤其首次 seekable 未就绪时）；
    /// 这里 time 与 position 双保险：先按 time 精确 seek，再用 position 兜底。
    func seek(to seconds: TimeInterval) {
        guard seconds >= 0 else { return }
        // 优先用 time（精确），但若媒体未标记 seekable 则 time 会静默失效
        if mediaPlayer.isSeekable {
            mediaPlayer.time = VLCTime(int: Int32(seconds * 1000))
        } else {
            // 兜底：用归一化 position（0~1）触发 seek
            if duration > 0 {
                mediaPlayer.position = Float(seconds / duration)
            }
        }
    }

    /// 相对跳转（秒，可正可负）。
    func jump(by seconds: TimeInterval) {
        if seconds > 0 {
            mediaPlayer.jumpForward(Int32(seconds))
        } else {
            mediaPlayer.jumpBackward(Int32(-seconds))
        }
    }

    /// 设置倍速。
    func setRate(_ rate: Float) {
        mediaPlayer.rate = rate
    }

    /// 上一帧 / 下一帧（单帧播放）。
    func stepFrameForward() {
        mediaPlayer.gotoNextFrame()
    }

    /// 上一帧：后退一小步并暂停（VLC 无直接上一帧，用跳转近似）。
    func stepFrameBackward() {
        let cur = TimeInterval(mediaPlayer.time.intValue) / 1000.0
        seek(to: max(0, cur - 1.0 / 30.0))
        mediaPlayer.pause() // 单帧后退后暂停在目标帧
    }

    /// 切换字幕轨道（index 对应 videoSubTitlesNames 索引；-1 关闭）。
    func selectSubtitleTrack(at index: Int) {
        // VLCKit 3.x：setCurrentVideoSubTitleIndex 切换字幕，-1 关闭。
        mediaPlayer.currentVideoSubTitleIndex = Int32(index)
    }

    /// 截图并保存（用于视频缩略图）。
    func captureSnapshot(completion: @escaping (UIImage?) -> Void) {
        // VLC iOS 提供 lastSnapshot（需先触发截图）
        // 用 saveVideoSnapshotAt 写临时文件再读回更可靠
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("vlc_snap_\(UUID().uuidString).png")
        mediaPlayer.saveVideoSnapshot(at: tmp.path, withWidth: 0, andHeight: 0)
        // VLC 截图是异步的，轮询读取
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let img = UIImage(contentsOfFile: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
            DispatchQueue.main.async { completion(img) }
        }
    }
}

// MARK: - PlayerControlOverlayDelegate

extension PlayerViewController: PlayerControlOverlayDelegate {

    func overlayDidTapPlayPause(_ overlay: PlayerControlOverlay) {
        togglePlayPause()
    }

    func overlay(_ overlay: PlayerControlOverlay, didSeekToProgress progress: Float) {
        guard duration > 0 else { return }
        let target = TimeInterval(progress) * duration
        seek(to: target)
    }

    func overlay(_ overlay: PlayerControlOverlay, didChangeRate rate: Float) {
        setRate(rate)
    }

    func overlayDidTapStepForward(_ overlay: PlayerControlOverlay) {
        stepFrameForward()
    }

    func overlayDidTapStepBackward(_ overlay: PlayerControlOverlay) {
        stepFrameBackward()
    }

    func overlay(_ overlay: PlayerControlOverlay, didSelectSubtitle index: Int) {
        selectSubtitleTrack(at: index)
    }

    func overlayDidTapClose(_ overlay: PlayerControlOverlay) {
        saveProgress()
        dismiss(animated: true)
    }
}

// MARK: - GestureManagerDelegate

extension PlayerViewController: GestureManagerDelegate {

    func gestureManagerDidToggleControls(_ manager: GestureManager) {
        overlay.toggleVisibility()
    }

    func gestureManager(_ manager: GestureManager, didChangeBrightness value: CGFloat) {
        UIScreen.main.brightness = max(0, min(1, value))
        overlay.showHint(text: String(format: "亮度 %.0f%%", UIScreen.main.brightness * 100))
    }

    func gestureManager(_ manager: GestureManager, didChangeVolume value: CGFloat) {
        VolumeController.setSystemVolume(Float(value))
        overlay.showHint(text: String(format: "音量 %.0f%%", value * 100))
    }

    func gestureManager(_ manager: GestureManager, didChangeZoom scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat) {
        // 先平移后缩放（正确的变换顺序：translate 在原始坐标系，再 scale）
        videoContainerView.transform = CGAffineTransform(translationX: offsetX, y: offsetY)
            .scaledBy(x: scale, y: scale)
    }

    // MARK: - 拖动快进（释放才 seek）

    func gestureManager(_ manager: GestureManager, didScrubTo seconds: TimeInterval) {
        overlay.showScrubPreview(seconds: seconds)
    }

    func gestureManager(_ manager: GestureManager, didFinishScrubAt seconds: TimeInterval) {
        seek(to: seconds)
        overlay.hideScrubPreview()
    }

    func gestureManagerCurrentTime(_ manager: GestureManager) -> TimeInterval {
        TimeInterval(mediaPlayer.time.intValue) / 1000.0
    }
}
