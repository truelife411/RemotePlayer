//
//  GestureManager.swift
//  RemotePlayer
//
//  视频播放手势管理（简化版）。
//  支持的手势：
//  - 单击 → 切换控制面板显隐
//  - 双击 → 播放/暂停
//  - 左右滑动（任意位置）→ 快进/快退，松手跳转（无预览）
//  - 双指捏合 → 缩放视频
//  - 缩放后单指拖动 → 平移画面
//  取消的手势：上下滑动调亮度/音量（改为拖竖向滑块）。
//

import UIKit

protocol GestureManagerDelegate: AnyObject {
    /// 单击：切换控制面板显隐
    func gestureManagerDidToggleControls(_ manager: GestureManager)
    /// 指针移动：用于唤起控制面板并重置自动隐藏计时
    func gestureManagerDidPointerMove(_ manager: GestureManager)
    /// 缩放/平移：更新视频容器的 transform
    func gestureManager(_ manager: GestureManager, didChangeZoom scale: CGFloat, offsetX: CGFloat, offsetY: CGFloat)
    /// 快进快退完成：跳转到指定秒数（松手时触发，无预览）
    func gestureManager(_ manager: GestureManager, didFinishScrubAt seconds: TimeInterval)
    /// 取得当前播放时间（用于计算水平滑动的目标时间）
    func gestureManagerCurrentTime(_ manager: GestureManager) -> TimeInterval
}

extension GestureManagerDelegate {
    func gestureManagerDidPointerMove(_ manager: GestureManager) {}
    func gestureManager(_ manager: GestureManager, didFinishScrubAt seconds: TimeInterval) {}
    func gestureManagerCurrentTime(_ manager: GestureManager) -> TimeInterval { 0 }
}

final class GestureManager: NSObject {

    weak var delegate: GestureManagerDelegate?
    private weak var player: PlayerGestureTarget?
    private weak var hostView: UIView?

    // pan 模式：本次拖动一旦确定就固定
    private enum PanMode { case none, horizontalScrub, panning }
    private var panMode: PanMode = .none

    // 缩放状态
    private(set) var currentScale: CGFloat = 1.0
    private(set) var panOffset: CGPoint = .zero
    private var pinchBaseScale: CGFloat = 1.0

    // 快进快退：起点时间 + 滑动起始 X
    private var scrubStartTime: TimeInterval = 0
    private var scrubStartX: CGFloat = 0

    /// 绑定到视频容器视图（位于 overlay 之下，让 overlay 上的交互控件先接收触摸）。
    func attach(to view: UIView, player: PlayerGestureTarget?) {
        self.hostView = view
        self.player = player

        // 单击：切控制层
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)

        // 双击：播放/暂停
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        view.addGestureRecognizer(doubleTap)
        // 单击需等待双击失败，避免双击时先触发单击
        tap.require(toFail: doubleTap)

        // pan：左右滑快进快退 / 缩放后拖动平移
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        view.addGestureRecognizer(pan)

        // pinch：缩放
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = self
        view.addGestureRecognizer(pinch)
        
        // hover: 指针移动
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        view.addGestureRecognizer(hover)
    }

    // MARK: - 手势处理

    @objc private func handleSingleTap() {
        delegate?.gestureManagerDidToggleControls(self)
    }

    @objc private func handleDoubleTap() {
        player?.togglePlayPause()
    }

    @objc private func handleHover(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            delegate?.gestureManagerDidPointerMove(self)
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = hostView else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)

        switch gesture.state {
        case .began:
            // 已放大时，单指拖动 = 平移画面
            if currentScale > 1.0 {
                panMode = .panning
            } else {
                // 仅水平方向明显的拖动才进入快进快退；纯垂直忽略
                if abs(velocity.x) > abs(velocity.y) {
                    panMode = .horizontalScrub
                    scrubStartTime = delegate?.gestureManagerCurrentTime(self) ?? 0
                    scrubStartX = gesture.location(in: view).x
                } else {
                    panMode = .none
                }
            }

        case .changed:
            switch panMode {
            case .horizontalScrub:
                // 松手才跳转，拖动期间不做预览（按需求：无预览）
                // 通知面板有交互，重置自动隐藏计时
                delegate?.gestureManagerDidScrubInProgress(self)
            case .panning:
                panOffset.x += translation.x
                panOffset.y += translation.y
                gesture.setTranslation(.zero, in: view)
                delegate?.gestureManager(self, didChangeZoom: currentScale,
                                         offsetX: panOffset.x, offsetY: panOffset.y)
            case .none:
                break
            }

        case .ended, .cancelled:
            if panMode == .horizontalScrub {
                // 用总位移估算目标时间：屏幕宽度对应总时长的一定比例。
                // 系数：横向滑过整个屏幕宽度 ≈ 跳转 90 秒（灵敏度适中）。
                let dx = gesture.location(in: view).x - scrubStartX
                let screenWidth = max(view.bounds.width, 1)
                let secondsPerPixel: CGFloat = 90.0 / screenWidth
                let delta = TimeInterval(dx * secondsPerPixel)
                let target = max(0, scrubStartTime + delta)
                delegate?.gestureManager(self, didFinishScrubAt: target)
            }
            panMode = .none

        default:
            break
        }
    }

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

// MARK: - UIGestureRecognizerDelegate

extension GestureManager: UIGestureRecognizerDelegate {

    /// pan 与 pinch 不可同时识别，避免双指拖动误判。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let isPan = gestureRecognizer is UIPanGestureRecognizer || other is UIPanGestureRecognizer
        let isPinch = gestureRecognizer is UIPinchGestureRecognizer || other is UIPinchGestureRecognizer
        if isPan && isPinch { return false }
        return true
    }

    /// 关键：当触摸落在交互控件（slider、按钮）上时，禁止 pan 手势识别，
    /// 否则拖动底部进度条 / 竖向滑块会被全屏 pan 拦截，误触发快进快退。
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer is UIPanGestureRecognizer {
            if let hitView = touch.view, hitView.isDescendantOfControl {
                return false
            }
        }
        return true
    }
}

// MARK: - 可选手势回调（拖动进行中的通知，用于重置面板自动隐藏计时）

extension GestureManagerDelegate {
    /// 拖动进行中（默认空实现，仅 PlayerViewController 实现：重置面板自动隐藏）。
    func gestureManagerDidScrubInProgress(_ manager: GestureManager) {}
}

// MARK: - UIView 辅助

private extension UIView {
    /// 判断本视图或其祖先是否为 UIControl（slider / button 等）。
    var isDescendantOfControl: Bool {
        var current: UIView? = self
        while let v = current {
            if v is UIControl { return true }
            current = v.superview
        }
        return false
    }
}

// MARK: - 播放手势目标协议

/// 暴露给 GestureManager 调用的播放控制接口。
protocol PlayerGestureTarget: AnyObject {
    func togglePlayPause()
}
