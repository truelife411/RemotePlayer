//
//  VolumeController.swift
//  RemotePlayer
//
//  系统音量控制。
//  iOS 无公开 API 直接设置系统音量，标准做法是使用 MPVolumeView
//  的（私有）slider，通过修改其 value 间接调整。
//  这里封装为可重用的单例。
//

import UIKit
import MediaPlayer
import AVFoundation

enum VolumeController {

    /// 隐藏的 MPVolumeSlider，用于间接设置系统音量。
    private static var volumeView: MPVolumeView?
    private static var volumeSlider: UISlider?

    /// 初始化（需在主线程调用一次）。
    static func warmUp() {
        guard volumeSlider == nil else { return }
        let view = MPVolumeView()
        view.isHidden = true
        // MPVolumeView 内部包含一个 UISlider
        if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
            volumeSlider = slider
        }
        volumeView = view
        // 加入 keyWindow 以确保生效
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.keyWindow })
            .first {
            window.addSubview(view)
        }
    }

    /// 当前系统音量 0...1。
    static var currentVolume: Float {
        warmUp()
        return volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume
    }

    /// 设置系统音量。
    static func setSystemVolume(_ volume: Float) {
        warmUp()
        DispatchQueue.main.async {
            // MPVolumeView 的 slider 必须在主线程设置
            volumeSlider?.value = max(0, min(1, volume))
        }
    }
}
