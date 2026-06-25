//
//  PlayerControlOverlay.swift
//  RemotePlayer
//
//  视频播放器的控制覆盖层（UIKit）。
//  布局（面板可见时）：
//  - 顶部：返回按钮、标题、字幕按钮
//  - 左侧：竖向亮度滑块
//  - 右侧：竖向音量滑块
//  - 底部：进度条（支持拖拽跳转）+ 时间 + 倍速按钮
//  - 缓冲指示居中
//  交互：单击屏幕切显隐；面板 5 秒无操作自动隐藏。
//

import UIKit

protocol PlayerControlOverlayDelegate: AnyObject {
    func overlay(_ overlay: PlayerControlOverlay, didSeekToProgress progress: Float)
    func overlay(_ overlay: PlayerControlOverlay, didChangeRate rate: Float)
    func overlay(_ overlay: PlayerControlOverlay, didSelectSubtitle index: Int)
    func overlayDidTapClose(_ overlay: PlayerControlOverlay)
    /// 播放/暂停按钮。
    func overlayDidTapPlayPause(_ overlay: PlayerControlOverlay)
    /// 亮度滑块拖动回调（0...1）
    func overlay(_ overlay: PlayerControlOverlay, didChangeBrightness value: CGFloat)
    /// 音量滑块拖动回调（0...1）
    func overlay(_ overlay: PlayerControlOverlay, didChangeVolume value: Float)
}

final class PlayerControlOverlay: UIView {

    weak var delegate: PlayerControlOverlayDelegate?

    // MARK: - 子视图

    private let topBar = UIView()
    private let bottomBar = UIView()
    /// 左侧亮度竖向滑块容器
    private let brightnessContainer = UIView()
    /// 右侧音量竖向滑块容器
    private let volumeContainer = UIView()

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

    private(set) lazy var rateButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("1x", for: .normal)
        b.tintColor = .white
        b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        b.addTarget(self, action: #selector(rateTapped), for: .touchUpInside)
        return b
    }()

    /// 播放/暂停按钮（右下角）。
    private(set) lazy var playPauseButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        b.tintColor = .white
        b.addTarget(self, action: #selector(playPauseTapped), for: .touchUpInside)
        return b
    }()

    /// 进度滑块（横向，底部）。
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

    /// 竖向亮度滑块（旋转 90° 的 UISlider）。
    private(set) lazy var brightnessSlider: UISlider = {
        let s = UISlider()
        s.minimumTrackTintColor = .systemOrange
        s.addTarget(self, action: #selector(brightnessChanged(_:)), for: .valueChanged)
        return s
    }()

    /// 竖向音量滑块。
    private(set) lazy var volumeSlider: UISlider = {
        let s = UISlider()
        s.minimumTrackTintColor = .systemOrange
        s.addTarget(self, action: #selector(volumeChanged(_:)), for: .valueChanged)
        return s
    }()

    /// 亮度图标（屏幕上方显示当前值）。
    private(set) lazy var brightnessIcon: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "sun.max"))
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    /// 音量图标。
    private(set) lazy var volumeIcon: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "speaker.wave.2"))
        iv.tintColor = .white
        iv.contentMode = .scaleAspectFit
        return iv
    }()

    /// 缓冲指示。
    private(set) lazy var bufferingIndicator: UIActivityIndicatorView = {
        let a = UIActivityIndicatorView(style: .large)
        a.color = .white
        a.hidesWhenStopped = true
        return a
    }()

    /// 临时提示（亮度/音量拖动反馈）。
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

    /// 关键：让 overlay 的透明区域"透传"触摸给下层的 videoContainerView。
    /// overlay 是覆盖全屏的 UIView，即使 isControlVisible=false，只要它自身
    /// isUserInteractionEnabled=true，hitTest 就会命中它、吞掉单击 → 手势面板出不来。
    /// 重写 hitTest：若该点命中的是 overlay 自己（而非某个可见子控件），返回 nil，
    /// 让触摸继续向下穿透到 videoContainerView（承载全屏手势的视图）。
    /// bufferingIndicator / hintLabel 需要正常显示但不拦截触摸，故命中它们也返回 nil。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        // 命中具体控件（按钮、滑块）时正常返回
        if let result, result !== self {
            // bufferingIndicator / hintLabel 不拦截触摸
            if result === bufferingIndicator || result === hintLabel {
                return nil
            }
            return result
        }
        // 命中 overlay 自身（透明空白区域）→ 透传给下层
        return nil
    }

    // MARK: - 布局

    private func setupSubviews() {
        // 顶部渐变背景
        let topGradient = makeGradientLayer(position: .top)
        topBar.layer.addSublayer(topGradient)
        let bottomGradient = makeGradientLayer(position: .bottom)
        bottomBar.layer.addSublayer(bottomGradient)

        addSubview(topBar)
        addSubview(bottomBar)
        addSubview(brightnessContainer)
        addSubview(volumeContainer)
        addSubview(bufferingIndicator)
        addSubview(hintLabel)

        topBar.addSubview(closeButton)
        topBar.addSubview(titleLabel)
        topBar.addSubview(subtitleButton)

        bottomBar.addSubview(currentTimeLabel)
        bottomBar.addSubview(slider)
        bottomBar.addSubview(durationLabel)
        bottomBar.addSubview(rateButton)
        bottomBar.addSubview(playPauseButton)

        brightnessContainer.addSubview(brightnessIcon)
        brightnessContainer.addSubview(brightnessSlider)
        volumeContainer.addSubview(volumeIcon)
        volumeContainer.addSubview(volumeSlider)

        // slider 点击手势：点击进度条直接跳转（不只拖）
        let sliderTap = UITapGestureRecognizer(target: self, action: #selector(sliderTapped(_:)))
        slider.addGestureRecognizer(sliderTap)
    }

    private func setupConstraints() {
        [topBar, bottomBar, brightnessContainer, volumeContainer, bufferingIndicator, hintLabel,
         closeButton, titleLabel, subtitleButton,
         currentTimeLabel, slider, durationLabel, rateButton, playPauseButton,
         brightnessIcon, brightnessSlider, volumeIcon, volumeSlider].forEach {
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
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: subtitleButton.leadingAnchor, constant: -12),

            subtitleButton.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -16),
            subtitleButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            subtitleButton.widthAnchor.constraint(equalToConstant: 32),
            subtitleButton.heightAnchor.constraint(equalToConstant: 32),

            // 底部栏
            bottomBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomBar.heightAnchor.constraint(equalToConstant: 96),

            // 时间标签（左上角，进度条上方）
            currentTimeLabel.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            currentTimeLabel.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -8),

            // 播放/暂停按钮：进度条同一行，左边
            playPauseButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            playPauseButton.centerYAnchor.constraint(equalTo: slider.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 32),
            playPauseButton.heightAnchor.constraint(equalToConstant: 32),

            // 进度条：按钮右边，留 10pt 间距
            slider.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10),
            slider.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            slider.bottomAnchor.constraint(equalTo: rateButton.topAnchor, constant: -4),

            durationLabel.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor, constant: -16),
            durationLabel.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),

            rateButton.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor, constant: 16),
            rateButton.bottomAnchor.constraint(equalTo: bottomBar.safeAreaLayoutGuide.bottomAnchor, constant: -8),

            // 左侧亮度容器：贴左边缘，垂直居中，高度大些好拖动
            brightnessContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            brightnessContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            brightnessContainer.widthAnchor.constraint(equalToConstant: 48),
            brightnessContainer.heightAnchor.constraint(equalToConstant: 280),

            // 右侧音量容器：贴右边缘，垂直居中
            volumeContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            volumeContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            volumeContainer.widthAnchor.constraint(equalToConstant: 48),
            volumeContainer.heightAnchor.constraint(equalToConstant: 280),

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

    /// 竖向滑块需在 layout 完成后旋转（UISlider 默认横向，旋转 -90° 后为竖向）。
    /// 同时更新 topBar/bottomBar 里的渐变 layer 尺寸。
    override func layoutSubviews() {
        super.layoutSubviews()

        // 渐变 layer 跟随 bar 尺寸（取 sublayers 第一个）
        if let g = topBar.layer.sublayers?.first { g.frame = topBar.bounds }
        if let g = bottomBar.layer.sublayers?.first { g.frame = bottomBar.bounds }

        // 亮度图标在容器顶部
        brightnessIcon.frame = CGRect(x: (brightnessContainer.bounds.width - 20) / 2,
                                      y: 0, width: 20, height: 20)
        // 亮度滑块：横向放置后旋转
        let bTrackHeight = brightnessContainer.bounds.height - brightnessIcon.frame.maxY - 6
        layoutVerticalSlider(brightnessSlider,
                             in: brightnessContainer,
                             topPadding: brightnessIcon.frame.maxY + 6,
                             trackHeight: bTrackHeight)

        // 音量图标在容器顶部
        volumeIcon.frame = CGRect(x: (volumeContainer.bounds.width - 20) / 2,
                                  y: 0, width: 20, height: 20)
        let vTrackHeight = volumeContainer.bounds.height - volumeIcon.frame.maxY - 6
        layoutVerticalSlider(volumeSlider,
                             in: volumeContainer,
                             topPadding: volumeIcon.frame.maxY + 6,
                             trackHeight: vTrackHeight)
    }

    /// 把一个 UISlider 在容器内旋转成竖向：先按横向尺寸摆好，再 transform 旋转 -90°。
    private func layoutVerticalSlider(_ slider: UISlider, in container: UIView, topPadding: CGFloat, trackHeight: CGFloat) {
        // 旋转后的可视高度 = 旋转前的宽度
        let sliderWidth = trackHeight
        let sliderHeight = container.bounds.width
        let originX = (container.bounds.width - sliderHeight) / 2
        let originY = topPadding
        // 关键：先设 frame，再设 transform；transform 改变时 frame 不再可靠，故禁用 AutoLayout
        slider.translatesAutoresizingMaskIntoConstraints = true
        slider.frame = CGRect(x: originX, y: originY, width: sliderHeight, height: sliderWidth)
        slider.transform = CGAffineTransform(rotationAngle: -.pi / 2)
        // 把旋转中心对齐到目标区域中心
        let targetCenter = CGPoint(x: container.bounds.width / 2,
                                   y: originY + trackHeight / 2)
        slider.center = targetCenter
    }

    // MARK: - 渐变

    private enum GradientPosition { case top, bottom }

    private func makeGradientLayer(position: GradientPosition) -> CAGradientLayer {
        let g = CAGradientLayer()
        g.colors = [UIColor.black.withAlphaComponent(0.6).cgColor, UIColor.clear.cgColor]
        g.locations = [0, 1]
        g.startPoint = .init(x: 0.5, y: position == .top ? 0 : 1)
        g.endPoint = .init(x: 0.5, y: position == .top ? 1 : 0)
        return g
    }

    // MARK: - 工厂

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

    private let rateOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    private var rateIndex = 2 // 默认 1.0x

    @objc private func rateTapped() {
        rateIndex = (rateIndex + 1) % rateOptions.count
        let rate = rateOptions[rateIndex]
        let label = rate == 1.0 ? "1x" : String(format: "%.2fx", rate)
        rateButton.setTitle(label, for: .normal)
        delegate?.overlay(self, didChangeRate: rate)
    }

    @objc private func playPauseTapped() {
        delegate?.overlayDidTapPlayPause(self)
    }

    @objc private func sliderChanged(_ sender: UISlider) {
        // 拖动中只更新 UI，跳转在释放时
        resetAutoHideTimer()
    }

    @objc private func sliderReleased(_ sender: UISlider) {
        isUserScrubbing = true
        delegate?.overlay(self, didSeekToProgress: sender.value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isUserScrubbing = false
        }
        resetAutoHideTimer()
    }

    /// 点击进度条直接跳转（不走拖动）。
    @objc private func sliderTapped(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: slider)
        let fraction = Float(point.x / slider.bounds.width)
        let value = max(0, min(1, fraction))
        slider.setValue(value, animated: true)
        isUserScrubbing = true
        delegate?.overlay(self, didSeekToProgress: value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isUserScrubbing = false
        }
        resetAutoHideTimer()
    }

    @objc private func brightnessChanged(_ sender: UISlider) {
        let value = CGFloat(sender.value)
        showHint(text: String(format: "亮度 %.0f%%", value * 100))
        delegate?.overlay(self, didChangeBrightness: value)
        resetAutoHideTimer()
    }

    @objc private func volumeChanged(_ sender: UISlider) {
        let value = sender.value
        showHint(text: String(format: "音量 %.0f%%", value * 100))
        delegate?.overlay(self, didChangeVolume: value)
        resetAutoHideTimer()
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

    func updateBuffering(_ isBuffering: Bool) {
        if isBuffering {
            bufferingIndicator.startAnimating()
        } else {
            bufferingIndicator.stopAnimating()
        }
    }

    /// 同步播放/暂停按钮图标。
    func updatePlaying(_ isPlaying: Bool) {
        let name = isPlaying ? "pause.fill" : "play.fill"
        playPauseButton.setImage(UIImage(systemName: name), for: .normal)
    }

    /// 用户是否正在拖动 slider 或手势快进（避免播放器回调把进度条弹回旧位置）。
    private var isUserScrubbing = false

    func updateTime(current: TimeInterval, duration: TimeInterval) {
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

    func updateSubtitleTracks(_ tracks: [SubtitleTrack]) {
        subtitleTracks = tracks
    }

    /// 同步亮度滑块位置（外部系统亮度变化时调用）。
    func updateBrightness(_ value: CGFloat) {
        // 避免回环：拖动中不覆盖
        if !brightnessSlider.isTracking {
            brightnessSlider.setValue(Float(value), animated: false)
        }
    }

    /// 同步音量滑块位置。
    func updateVolume(_ value: Float) {
        if !volumeSlider.isTracking {
            volumeSlider.setValue(value, animated: false)
        }
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

    // MARK: - 显隐 + 自动隐藏

    /// 控件可见时，控制条/按钮需要接收触摸（slider 拖拽、按钮点击）；
    /// 不可见时透传触摸给下层的视频容器，让全屏手势（pan/pinch/tap）正常工作。
    private var isControlVisible = false

    /// 5 秒无操作自动隐藏计时
    private var autoHideWork: DispatchWorkItem?
    private let autoHideDelay: TimeInterval = 5.0

    func toggleVisibility() {
        isControlVisible.toggle()
        applyVisibility(animated: true)
        if isControlVisible {
            resetAutoHideTimer()
        } else {
            cancelAutoHideTimer()
        }
    }

    /// 通知面板有用户交互（如外部手势 seek），重置自动隐藏计时。
    func notifyUserInteraction() {
        if isControlVisible {
            resetAutoHideTimer()
        }
    }

    private func resetAutoHideTimer() {
        autoHideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isControlVisible else { return }
            self.isControlVisible = false
            self.applyVisibility(animated: true)
        }
        autoHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + autoHideDelay, execute: work)
    }

    private func cancelAutoHideTimer() {
        autoHideWork?.cancel()
        autoHideWork = nil
    }

    private func applyVisibility(animated: Bool) {
        let alpha: CGFloat = isControlVisible ? 1 : 0
        // 子栏的交互开关跟随可见性
        topBar.isUserInteractionEnabled = isControlVisible
        bottomBar.isUserInteractionEnabled = isControlVisible
        brightnessContainer.isUserInteractionEnabled = isControlVisible
        volumeContainer.isUserInteractionEnabled = isControlVisible
        let block = {
            self.topBar.alpha = alpha
            self.bottomBar.alpha = alpha
            self.brightnessContainer.alpha = alpha
            self.volumeContainer.alpha = alpha
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
