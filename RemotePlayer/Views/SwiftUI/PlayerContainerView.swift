//
//  PlayerContainerView.swift
//  RemotePlayer
//
//  SwiftUI 桥接：用 UIViewControllerRepresentable 包装 UIKit 的 PlayerViewController。
//  负责：
//  - 播放前准备（prepare：注册代理、下载字幕、读续播位置）
//  - 创建 PlayerViewController 并注入准备好的 URL/字幕/起始位置
//  - 把 delegate 事件转发回 PlayerViewModel
//

import SwiftUI
import MobileVLCKit

struct PlayerContainerView: View {

    let file: SMBFile
    let serverID: UUID?

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: PlayerViewModel?
    @State private var prepared = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let viewModel, prepared, let streamURL = viewModel.streamURL {
                PlayerUIView(streamURL: streamURL,
                             startPosition: viewModel.startPosition,
                             externalSubtitleURL: viewModel.localSubtitleURL,
                             title: file.name,
                             onProgress: { pos, dur, rate in
                                 viewModel.onProgressUpdate(position: pos, duration: dur, rate: rate)
                             },
                             onThumbnail: { image in
                                 viewModel.registerThumbnail(image)
                             })
                .ignoresSafeArea()
            } else {
                // 准备中
                ProgressView("正在准备播放…")
                    .tint(.white)
                    .foregroundStyle(.white)
            }
        }
        .task {
            guard viewModel == nil else { return }
            let vm = PlayerViewModel(file: file, serverID: serverID, coordinator: coordinator)
            viewModel = vm
            await vm.prepare()
            prepared = true
        }
        .onDisappear {
            viewModel?.cleanup()
        }
    }
}

// MARK: - UIViewControllerRepresentable

/// 包装 PlayerViewController 的 SwiftUI 视图。
struct PlayerUIView: UIViewControllerRepresentable {

    let streamURL: URL
    let startPosition: TimeInterval
    let externalSubtitleURL: URL?
    let title: String
    let onProgress: (TimeInterval, TimeInterval, Float) -> Void
    let onThumbnail: (UIImage) -> Void

    func makeUIViewController(context: Context) -> PlayerViewController {
        let vc = PlayerViewController(streamURL: streamURL,
                                      startPosition: startPosition,
                                      externalSubtitleURL: externalSubtitleURL)
        vc.delegate = context.coordinator
        vc.overlay.updateTitle(title)

        // 进度保存回调
        vc.progressSaver = { pos, dur, rate in
            onProgress(pos, dur, rate)
        }
        vc.progressClearer = nil

        // 截图注册缩略图（首帧出现后触发一次）
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak vc] in
            vc?.captureSnapshot { image in
                if let image {
                    onThumbnail(image)
                }
            }
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: PlayerViewController, context: Context) {
        // 无需更新
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onProgress: onProgress)
    }

    final class Coordinator: NSObject, PlayerViewControllerDelegate {
        let onProgress: (TimeInterval, TimeInterval, Float) -> Void

        init(onProgress: @escaping (TimeInterval, TimeInterval, Float) -> Void) {
            self.onProgress = onProgress
        }

        func player(_ player: PlayerViewController, didChangeState state: VLCMediaPlayerState) {}
        func player(_ player: PlayerViewController, didChangeTime seconds: TimeInterval, duration: TimeInterval) {}
        func player(_ player: PlayerViewController, didChangePlaying isPlaying: Bool) {}
        func player(_ player: PlayerViewController, didDiscoverTextTracks tracks: [SubtitleTrack]) {}
        func player(_ player: PlayerViewController, didEncounterError message: String) {}
    }
}
