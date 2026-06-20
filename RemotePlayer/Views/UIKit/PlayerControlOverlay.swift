//
//  PlayerControlOverlay.swift
//  RemotePlayer
//
//  视频播放器的控制覆盖层（UIKit）。
//  功能：
//  - 顶部：返回按钮、标题
//  - 中部：播放/暂停、倍速、单帧前进/后退、缓冲指示
//  - 底部：进度条（支持拖拽跳转）、时间、字幕选择、关闭
//  - 临时提示（亮度/音量调节反馈）
//

import UIKit

protocol PlayerControlOverlayDelegate: AnyObject {
    func overlayDidTapPlayPause(_ overlay: PlayerControlOverlay)
    func overlay(_ overlay: PlayerControlOverlay, didSeekToProgress progress: Float)
    func overlay(_ overlay: PlayerControlOverlay, didChangeRate rate: Float)
    func overlayDidTapStepForward(_ overlay: PlayerControlOverlay)
    func overlayDidTapStepBackward(_ overlay: PlayerControlOverlay)
    func overlay(_ overlay: PlayerControlOverlay, didSelectSubtitle index: Int)
    func overlayDidTapClose(_ overlay: PlayerControlOverlay)
}

final class PlayerControlOverlay: UIView {

    weak var delegate: PlayerControlOverlayDelegate?

    // MARK: - 子视图

    private let topBar = UIView()
    private let bottomBar = UIView()
    private let centerControls = UIView()

    private(set) lazy var closeButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "xmark"), for: .normal)
        b.tintColor = .white
        b.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return b
    }()

    private(set) lazy var titleLabel: UILabel = {
        let l = UILabel()
        l.textColor = .white
        l.font = .systemFont(ofSize: 16, weight: .medium)
        return l
    }()

    private(set) lazy var playPauseButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        b.tintColor = .white
        b.titleLabel?.font = .systemFont(ofSize: 28)
        b.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        return b
    }()

    private(set) lazy var stepBackwardButton: UIButton = makeStepButton("backward.frame", action: #selector(stepBackwardTapped))
    private(set) lazy var stepForwardButton: UIButton = makeStepButton("forward.frame", action: #selector(stepForwardTapped))

    private(set) lazy var rateButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("1.0x", for: .normal)
        b.tintColor = .white
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.addTarget(self, action: #selector(rateTapped), for: .touchUpInside)
        return b
    }()

    /// 进度滑块。
    private(set) lazy var slider: UISlider = {
        let s = UISlider()
        s.minimumTrackTintColor = .systemOrange
        s.addTarget(self, action: #selector(sliderChanged(_:)), for: .valueChanged)
        s.addTarget(self, action: #selector(sliderReleased(_:)), for: [.touchUpInside, .touchUpOutside])
        return s
    }()

    private(set) lazy var currentTimeLabel = makeTimeLabel()
    private(set) lazy var durationLabel = makeTimeLabel()

    /// 字幕按钮。
    private(set) lazy var subtitleButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "captions.bubble"), for: .normal)
        b.tintColor = .white
        b.addTarget(self, action: #selector(subtitleTapped), for: .touchUpInside)
        return b
    }()

    /// 缓冲指示。
    private(set) lazy var bufferingIndicator: UIActivityIndicatorView = {
        let a = UIActivityIndicatorView(style: .large)
        a.color = .white
        a.hidesWhenStopped = true
        return a
    }()

    /// 临时提示（亮度/音量）。
    private(set) lazy var hintLabel: UILabel = {
        let l = UILabel()
        l.textColor = .white
        l.font = .systemFont(ofSize: 14, weight: .medium)
        l.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        l.textAlignment = .center
        l.layer.cornerRadius = 8
        l.layer.masksToBounds = true
        l.isHidden = true
        return l
    }()

    // 字幕轨道列表
    private var subtitleTracks: [SubtitleTrack] = []

    // MARK: - 初始化

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        setupSubviews()
        setupConstraints()
        // 初始隐藏控制层（点击显示）
        applyVisibility(animated: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 布局

    private func setupSubviews() {
        // 顶部渐变背景
        let topGradient = makeGradientLayer(position: .top)
        topBar.layer.addSublayer(topGradient)
        let bottomGradient = makeGradientLayer(position: .bottom)
        bottomBar.layer.addSublayer(bottomGradient)

        addSubview(topBar)
        addSubview(bottomBar)
        addSubview(centerControls)
        addSubview(bufferingIndicator)
        addSubview(hintLabel)

        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)

        centerControls.addSubview(stepBackwardButton)
        centerControls.addSubview(playPauseButton)
        centerControls.addSubview(stepForwardButton)

        bottomBar.addSubview(currentTimeLabel)
        bottomBar.addSubview(slider)
        bottomBar.addSubview(durationLabel)
        bottomBar.addSubview(rateButton)
        bottomBar.addSubview(subtitleButton)
    }

    private func setupConstraints() {
        [topBar, bottomBar, centerControls, bufferingIndicator, hintLabel,
         closeButton, titleLabel, playPauseButton, stepBackwardButton, stepForwardButton,
         currentTimeLabel, slider, durationLabel, rateButton, subtitleButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        NSLayoutConstraint.activate([
            // 顶部栏
            topBar.topAnchor.constraint(equalTo: topAnchor),
            topBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 88),

            closeButton.leadingAnchor.constraint(equalTo: topBar.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: topBar.safeAreaLayoutGuide.topAnchor, constant: 8),
            closeButton.widthAnchor.constraint(equalToConstant: 32),
            closeButton.heightAnchor.constraint(equalToConstant: 32),

            titleLabel.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor, constant: -16),

            // 中部控制
            centerControls.centerYAnchor.constraint(equalTo: centerYAnchor),
            centerControls.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerControls.heightAnchor.constraint(equalToConstant: 80),

            stepBackwardButton.leadingAnchor.constraint(equalTo: centerControls.leadingAnchor),
            stepBackwardButton.centerYAnchor.constraint(equalTo: centerControls.centerYAnchor),
            stepBackwardButton.widthAnchor.constraint(equalToConstant: 48),
            stepBackwardButton.heightAnchor.constraint(equalToConstant: 48),

            playPauseButton.centerXAnchor.constraint(equalTo: centerControls.centerXAnchor),
            playPauseButton.centerYAnchor.constraint(equalTo: centerControls.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 64),
            playPauseButton.heightAnchor.constraint(equalToConstant: 64),

            stepForwardButton.trailingAnchor.constraint(equalTo: centerControls.trailingAnchor),
            stepForwardButton.centerYAnchor.constraint(equalTo: centerControls.centerYAnchor),
            stepForwardButton.widthAnchor.constraint(equalToConstant: 48),
            stepForwardButton.heightAnchor.constraint(equalToConstant: 48),

            // 底部栏
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 96),

            currentTimeLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            currentTimeLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -8),

            slider.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            slider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            slider.bottomAnchor.constraint(equalTo: rateButton.topAnchor, constant: -4),

            durationLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            durationLabel.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),

            rateButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            subtitleButton.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            rateButton.bottomAnchor.constraint(equalTo: bottomBar.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            subtitleButton.centerYAnchor.constraint(equalTo: rateButton.centerYAnchor),

            // 缓冲指示居中
            bufferingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            bufferingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),

            // 提示标签
            hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            hintLabel.heightAnchor.constraint(equalToConstant: 40)
        ])
    }

    // MARK: - 渐变背景

    private enum GradientPosition { case top, bottom }

    private func makeGradientLayer(position: GradientPosition) -> CAGradientLayer {
        let g = CAGradientLayer()
        if position == .top {
            g.colors = [UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.clear.cgColor]
            g.startPoint = CGPoint(x: 0.5, y: 0)
            g.endPoint = CGPoint(x: 0.5, y: 1)
        } else {
            g.colors = [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.6).cgColor]
            g.startPoint = CGPoint(x: 0.5, y: 0)
            g.endPoint = CGPoint(x: 0.5, y: 1)
        }
        return g
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        topBar.layer.sublayers?.first?.frame = topBar.bounds
        let bottomGrad = bottomBar.layer.sublayers?.first
        bottomGrad?.frame = bottomBar.bounds
    }

    // MARK: - 工厂

    private func makeStepButton(_ icon: String, action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: icon), for: .normal)
        b.tintColor = .white
        b.addTarget(self, action: action, for: .touchUpInside)
        return b
    }

    private func makeTimeLabel() -> UILabel {
        let l = UILabel()
        l.textColor = .white
        l.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        l.text = "00:00"
        return l
    }

    // MARK: - 动作

    @objc private func closeTapped() {
        delegate?.overlayDidTapClose(self)
    }

    @objc private func playPauseTapped() {
        delegate?.overlayDidTapPlayPause(self)
    }

    @objc private func stepBackwardTapped() {
        delegate?.overlayDidTapStepBackward(self)
    }

    @objc private func stepForwardTapped() {
        delegate?.overlayDidTapStepForward(self)
    }

    private let rateOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private var rateIndex = 2 // 默认 1.0x

    @objc private func rateTapped() {
        rateIndex = (rateIndex + 1) % rateOptions.count
        let rate = rateOptions[rateIndex]
        let label = rate == 1.0 ? "1x" : String(format: "%.2fx", rate)
        rateButton.setTitle(label, for: .normal)
        delegate?.overlay(self, didChangeRate: rate)
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        // 拖动中只更新 UI，跳转在释放时
    }

    @objc private func sliderReleased(_ sender: UISlider) {
        isUserScrubbing = true
        delegate?.overlay(self, didSeekToProgress: sender.value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isUserScrubbing = false
        }
    }

    @objc private func subtitleTapped() {
        showSubtitleMenu()
    }

    // MARK: - 字幕菜单

    private func showSubtitleMenu() {
        var actions: [(String, Int)] = [("关闭字幕", -1)]
        for (idx, track) in subtitleTracks.enumerated() {
            actions.append((track.name, idx))
        }

        let alert = UIAlertController(title: "选择字幕", message: nil, preferredStyle: .actionSheet)
        for (title, idx) in actions {
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                self.delegate?.overlay(self, didSelectSubtitle: idx)
            })
        }
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))

        // 用 responder chain 找到最近的 VC 来 present
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let vc = next as? UIViewController {
                if let pop = alert.popoverPresentationController {
                    pop.sourceView = subtitleButton
                    pop.sourceRect = subtitleButton.bounds
                }
                vc.present(alert, animated: true)
                return
            }
            responder = next
        }
    }

    // MARK: - 状态更新

    func updateTitle(_ text: String) {
        titleLabel.text = text
    }

    func updatePlaying(_ isPlaying: Bool) {
        let icon = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: icon), for: .normal)
    }

    func updateBuffering(_ isBuffering: Bool) {
        if isBuffering {
            bufferingIndicator.startAnimating()
        } else {
            bufferingIndicator.stopAnimating()
        }
    }

    /// 用户是否正在拖动 slider 或手势快进（避免播放器回调把进度条弹回旧位置）。
    private var isUserScrubbing = false
    /// 当前播放时长（供 scrub 预览计算进度条位置）。
    private var currentDuration: TimeInterval = 0

    func updateTime(current: TimeInterval, duration: TimeInterval) {
        currentDuration = duration
        if !isUserScrubbing {
            currentTimeLabel.text = formatTime(current)
        }
        durationLabel.text = formatTime(duration)
        guard duration > 0 else { return }
        // 仅在非拖动状态下同步进度
        if !slider.isTracking && !isUserScrubbing {
            slider.setValue(Float(current / duration), animated: false)
        }
    }

    /// 手势/进度条拖动时显示预览时间。
    func showScrubPreview(seconds: TimeInterval) {
        isUserScrubbing = true
        currentTimeLabel.text = formatTime(seconds)
        if currentDuration > 0 {
            slider.setValue(Float(seconds / currentDuration), animated: false)
        }
    }

    func hideScrubPreview() {
        // 延迟复位，给 seek 完成一点时间
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isUserScrubbing = false
        }
    }

    func updateSubtitleTracks(_ tracks: [SubtitleTrack]) {
        subtitleTracks = tracks
    }

    // MARK: - 提示

    private var hintWorkItem: DispatchWorkItem?

    func showHint(text: String) {
        hintLabel.text = text
        hintLabel.isHidden = false
        hintWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hintLabel.isHidden = true
        }
        hintWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: - 显隐

    func toggleVisibility() {
        isControlVisible.toggle()
        applyVisibility(animated: true)
    }

    private var isControlVisible = false

    private func applyVisibility(animated: Bool) {
        let alpha: CGFloat = isControlVisible ? 1 : 0
        let block = {
            self.topBar.alpha = alpha
            self.bottomBar.alpha = alpha
            self.centerControls.alpha = alpha
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: block)
        } else {
            block()
        }
    }

    // MARK: - 工具

    private func formatTime(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let s = Int(t)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
