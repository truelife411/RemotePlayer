//
//  ImageViewerView.swift
//  RemotePlayer
//
//  图片浏览器（SwiftUI）。
//  功能：
//  - 全屏查看，黑色背景
//  - 先显示低清模糊缩略图，后台加载原图，完成后无缝替换
//  - 双指捏合缩放、双击放大/还原
//  - 左右滑动切换同目录图片
//  - 顶部关闭按钮
//

import SwiftUI

struct ImageViewerView: View {

    /// 当前图片。
    @State var currentFile: SMBFile
    /// 同目录所有图片（用于左右切换）。
    let siblings: [SMBFile]
    let serverID: UUID?

    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    /// 当前索引（用 Int 作 TabView selection，避免对象绑定在 sheet 里的索引错位 bug）。
    @State private var currentIndex: Int = 0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                TabView(selection: $currentIndex) {
                    ForEach(Array(siblings.enumerated()), id: \.element.id) { index, file in
                        ZoomableAsyncImage(file: file, smbService: coordinator.smbService)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: siblings.count > 1 ? .automatic : .never))
                .ignoresSafeArea()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(currentIndex + 1) / \(siblings.count)")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(.black.opacity(0.4), in: Capsule())
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        // onAppear 时把选中索引对齐到 currentFile（sheet 打开后只跑一次）
        .onAppear {
            currentIndex = siblings.firstIndex(where: { $0.id == currentFile.id }) ?? 0
        }
        // 翻页时同步 currentFile（供标题/父视图使用）
        .onChange(of: currentIndex) { newIndex in
            if newIndex >= 0 && newIndex < siblings.count {
                currentFile = siblings[newIndex]
            }
        }
    }
}

// MARK: - 可缩放的远程图片

/// 渐进式加载的缩放图片：
/// 1. 先取缩略图（ThumbnailService，快速、模糊）
/// 2. 后台读取原图
/// 3. 原图就绪后替换
/// 支持双指缩放 + 双击放大。
struct ZoomableAsyncImage: View {

    let file: SMBFile
    let smbService: SMBService

    @State private var thumbnail: UIImage?
    @State private var fullImage: UIImage?
    @State private var isLoadingFull = false
    @State private var loadFailed = false

    // 缩放状态
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let fullImage {
                    imageContent(fullImage, geo: geo)
                } else if let thumbnail {
                    // 显示模糊缩略图
                    imageContent(thumbnail, geo: geo)
                        .blur(radius: 10)
                        .overlay {
                            if isLoadingFull {
                                ProgressView()
                                    .tint(.white)
                            }
                        }
                } else if loadFailed {
                    ContentUnavailableView("无法加载", systemImage: "photo.bad")
                        .foregroundStyle(.white)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .task(id: file.id) {
            await loadImages()
        }
    }

    @ViewBuilder
    private func imageContent(_ image: UIImage, geo: GeometryProxy) -> some View {
        let aspect = image.size.width / image.size.height
        let geoAspect = geo.size.width / geo.size.height
        let fitSize: CGSize = aspect > geoAspect ?
            CGSize(width: geo.size.width, height: geo.size.width / aspect) :
            CGSize(width: geo.size.height * aspect, height: geo.size.height)

        // 关键：clipped 放在容器（屏幕）层级，而不是图片 fitSize 层级。
        // 否则 scaleEffect 放大时，图片会在原 fitSize 边界处被裁断，
        // 看起来像"在原来的框里放大"。
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: fitSize.width, height: fitSize.height)
            .scaleEffect(scale, anchor: .center)
            .offset(offset)
            .gesture(
                MagnificationGesture()
                    .onChanged { value in
                        scale = lastScale * value
                    }
                    .onEnded { _ in
                        lastScale = scale
                        if scale < 1.0 {
                            withAnimation(.spring()) {
                                scale = 1.0
                                lastScale = 1.0
                                offset = .zero
                                lastOffset = .zero
                            }
                        } else if scale > 5.0 {
                            scale = 5.0
                            lastScale = 5.0
                        }
                    }
            )
            // 放大后可拖动
            .gesture(
                scale > 1.0 ?
                DragGesture()
                    .onChanged { value in
                        offset = CGSize(width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { _ in
                        lastOffset = offset
                    } : nil
            )
            // 双击切换放大/还原
            .onTapGesture(count: 2) {
                withAnimation(.spring()) {
                    if scale > 1.0 {
                        scale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                    }
                }
            }
            // 容器裁剪：放大内容只在屏幕范围内可见
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
    }

    // MARK: - 加载

    private func loadImages() async {
        fullImage = nil
        thumbnail = nil
        isLoadingFull = false
        loadFailed = false

        // 1. 缩略图（快速）
        thumbnail = await ThumbnailService.shared.imageThumbnail(
            smbService: smbService,
            filePath: file.path,
            size: CGSize(width: 100, height: 100)
        )

        // 2. 后台加载原图
        isLoadingFull = true
        do {
            let data = try await smbService.readEntireFile(file.path)
            if let img = UIImage(data: data) {
                fullImage = img
            } else {
                loadFailed = true
            }
        } catch {
            loadFailed = true
        }
        isLoadingFull = false
    }
}
