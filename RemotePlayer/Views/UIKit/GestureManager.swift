//
//  GestureManager.swift
//  RemotePlayer
//
//  手势系统（UIKit）。
//  - 单击：切换控制层显隐
//  - 双击：播放 / 暂停
//  - 水平滑动：快进 / 快退（释放时才 seek，避免频繁缓冲）
//  - 左侧垂直滑动：调整亮度
//  - 右侧垂直滑动：调整音量
//  - 双指捏合：缩放画面
//  - 缩放后单指拖动：平移查看放大区域
//

import UIKit

protocol GestureManagerDelegate: AnyObject {
    func gestureManagerDidToggleControls(_ manager: GestureManager)
    func gestureManager(_ manager: GestureManager, didChangeBrightness value: CGFloat)
    func gestureManager(_ manager: GestureManager, didChangeVolume value: CGFloat)
    func gestureManager(_ manager: GestureManager, didChangeZoom scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat)
    /// 拖动快进过程中实时显示预览时间（不 seek）。
    func gestureManager(_ manager: GestureManager, didScrubTo seconds: TimeInterval)
    /// 拖动结束，执行 seek。
    func gestureManager(_ manager: GestureManager, didFinishScrubAt seconds: TimeInterval)
    /// 当前播放时间（供手势计算偏移量用）。
    func gestureManagerCurrentTime(_ manager: GestureManager) -> TimeInterval
}

extension GestureManagerDelegate {
    func gestureManager(_ manager: GestureManager, didScrubTo seconds: TimeInterval) {}
    func gestureManager(_ manager: GestureManager, didFinishScrubAt seconds: TimeInterval) {}
    func gestureManagerCurrentTime(_ manager: GestureManager) -> TimeInterval { 0 }
}

final class GestureManager: NSObject, UIGestureRecognizerDelegate {

    weak var delegate: GestureManagerDelegate?

    private weak var attachedView: UIView?
    private weak var player: PlayerViewController?

    private enum PanMode {
        case none
        case horizontalScrub
        case verticalBrightness
        case verticalVolume
        case panning          // 缩放后平移
    }

    private var panMode: PanMode = .none
    private var scrubStartTime: TimeInterval = 0

    private var startBrightness: CGFloat = 0
    private var startVolume: CGFloat = 0

    private var currentScale: CGFloat = 1.0
    private var panOffset: CGPoint = .zero
    private var pinchBaseScale: CGFloat = 1.0

    // MARK: - 挂载

    func attach(to view: UIView, player: PlayerViewController) {
        self.attachedView = view
        self.player = player

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        tap.numberOfTapsRequired = 1
        tap.delegate = self

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = self
        tap.require(toFail: doubleTap)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self

        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(pinch)

        VolumeController.warmUp()
    }

    // MARK: - UIGestureRecognizerDelegate

    /// pan 与 pinch 不可同时识别，避免双指拖动误判。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let isPan = gestureRecognizer is UIPanGestureRecognizer || other is UIPanGestureRecognizer
        let isPinch = gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
        // pan 和 pinch 互斥
        if isPan && isPinch { return false }
        return true
    }

    /// 关键：当触摸落在交互控件（slider、按钮）上时，禁止 pan 手势识别，
    /// 否则拖动进度条会被全屏 pan 拦截，误触发音量/亮度调节。
    /// touchesView 链上只要含 UIControl，就让手势让位。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        // 只约束 pan（slider 拖拽要顺畅）；tap/pinch 不受影响
        if gestureRecognizer is UIPanGestureRecognizer {
            if let hitView = touch.view, hitView.isDescendantOfControl {
                return false
            }
        }
        return true
    }

    // MARK: - 单击 / 双击

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        delegate?.gestureManagerDidToggleControls(self)
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        player?.togglePlayPause()
    }

    // MARK: - 拖动

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = attachedView else { return }
        let location = gesture.location(in: view)
        let translation = gesture.translation(in: view)

        switch gesture.state {
        case .began:
            // 已放大时，单指拖动 = 平移
            if currentScale > 1.0 {
                panMode = .panning
                return
            }
            if abs(translation.x) > abs(translation.y) {
                panMode = .horizontalScrub
                scrubStartTime = delegate?.gestureManagerCurrentTime(self) ?? 0
            } else {
                if location.x < view.bounds.midX {
                    panMode = .verticalBrightness
                    startBrightness = UIScreen.main.brightness
                } else {
                    panMode = .verticalVolume
                    startVolume = CGFloat(VolumeController.currentVolume)
                }
            }

        case .changed:
            switch panMode {
            case .horizontalScrub:
                // 拖动中只更新预览，不 seek（避免频繁缓冲）
                let delta = TimeInterval(translation.x)
                let target = max(0, scrubStartTime + delta)
                delegate?.gestureManager(self, didScrubTo: target)

            case .verticalBrightness:
                let delta = -translation.y / view.bounds.height
                delegate?.gestureManager(self, didChangeBrightness: max(0, min(1, startBrightness + delta)))

            case .verticalVolume:
                let delta = -translation.y / view.bounds.height
                delegate?.gestureManager(self, didChangeVolume: max(0, min(1, startVolume + delta)))

            case .panning:
                panOffset.x += translation.x
                panOffset.y += translation.y
                gesture.setTranslation(.zero, in: view)
                delegate?.gestureManager(self, didChangeZoom: currentScale,
                                         offsetX: panOffset.x, offsetY: panOffset.y)

            case .none:
                break
            }

        case .ended, .cancelled, .failed:
            if panMode == .horizontalScrub {
                let delta = TimeInterval(translation.x)
                let target = max(0, scrubStartTime + delta)
                delegate?.gestureManager(self, didFinishScrubAt: target)
            }
            panMode = .none

        @unknown default:
            break
        }
    }

    // MARK: - 双指缩放

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            pinchBaseScale = currentScale
            panMode = .none // 取消进行中的 pan
        case .changed:
            let newScale = max(1.0, min(5.0, pinchBaseScale * gesture.scale))
            currentScale = newScale
            delegate?.gestureManager(self, didChangeZoom: newScale,
                                     offsetX: panOffset.x, offsetY: panOffset.y)
        case .ended:
            if currentScale < 1.05 {
                currentScale = 1.0
                panOffset = .zero
                delegate?.gestureManager(self, didChangeZoom: 1.0, offsetX: 0, offsetY: 0)
            }
        default:
            break
        }
    }
}

// MARK: - UIView 辅助

private extension UIView {
    /// 判断本视图或其祖先是否为 UIControl（slider / button 等）。
    /// 用于手势 delegate 判定拖动是否落在可交互控件上。
    var isDescendantOfControl: Bool {
        var current: UIView? = self
        while let v = current {
            if v is UIControl { return true }
            current = v.superview
        }
        return false
    }
}
