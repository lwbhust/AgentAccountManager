import SwiftUI
import AppKit

/// 窗口背景：星空山脉照片 + 磨砂罩 + 极慢的漂移。
///
/// 设计取舍：
/// - 背景只负责氛围，照片之上必须压一层系统磨砂材质，保证正文与按钮的对比度；
/// - 漂移幅度很小（缩放 1.03–1.09、位移 10–14pt），几十秒一循环，不抢注意力；
/// - 尊重"减少动态效果"，此时保持静态构图；
/// - 窗口失焦或关闭开关时暂停时间轴，不在后台持续渲染。
/// 可选的沉浸式背景照片，与打包脚本中的 Background-<key>.jpg 资源一一对应。
enum BackgroundPhoto: String, CaseIterable, Identifiable {
    case starlight
    case aurora
    case dawn
    case nebula
    case forest
    case rainy
    case coast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .starlight: return "星空之夜"
        case .aurora: return "极光峡湾"
        case .dawn: return "晨曦湖畔"
        case .nebula: return "深空星云"
        case .forest: return "雾林晨光"
        case .rainy: return "雨夜霓虹"
        case .coast: return "海岸暮色"
        }
    }

    static let storageKey = "backgroundPhoto"
    static let defaultValue: BackgroundPhoto = .starlight
}

struct WindowBackground: View {
    /// 裁切对齐方式：窄列（如侧边栏）贴底裁切，让明亮的极光带落在可视区中部，
    /// 而不是只露出顶部的大片暗夜空。
    var alignment: Alignment = .center

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @AppStorage(AppearanceSetting.backgroundKey) private var enabled = true
    @AppStorage(BackgroundPhoto.storageKey) private var photoRaw = BackgroundPhoto.defaultValue.rawValue

    /// 20fps 足以表现极慢的漂移，又明显低于屏幕刷新率。
    private static let frameInterval: TimeInterval = 1.0 / 20.0

    private var isPaused: Bool {
        reduceMotion || controlActiveState != .active
    }

    var body: some View {
        Group {
            if enabled {
                GeometryReader { proxy in
                    ZStack {
                        artwork
                            .frame(width: proxy.size.width, height: proxy.size.height, alignment: alignment)
                            .clipped()
                        frostedVeil
                    }
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var artwork: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: isPaused)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                if let image = Self.image(for: currentPhoto) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .id(currentPhoto)
                        .transition(.opacity)
                } else {
                    fallbackArtwork
                }
            }
            .animation(.easeInOut(duration: 0.6), value: currentPhoto)
            .scaleEffect(1.06 + 0.03 * sin(t / 52 * .circle))
            .offset(
                x: 14 * sin(t / 73 * .circle),
                y: 10 * cos(t / 61 * .circle)
            )
        }
    }

    private var currentPhoto: BackgroundPhoto {
        BackgroundPhoto(rawValue: photoRaw) ?? .starlight
    }

    /// 照片之上的整体薄纱：按深浅色模式提亮/压暗照片。
    /// 遮罩只做必要的对比度补偿，越薄极光的通透感越强。
    private var frostedVeil: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(colorScheme == .light
                      ? Color.white.opacity(0.10)
                      : Color.black.opacity(0.15))
            Rectangle()
                .fill(LinearGradient(
                    stops: [
                        .init(color: colorScheme == .light
                              ? Color.white.opacity(0.28)
                              : Color.black.opacity(0.20), location: 0),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(height: 170)
        }
    }

    private var fallbackArtwork: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.09, blue: 0.18),
                Color(red: 0.07, green: 0.18, blue: 0.22),
                Color(red: 0.04, green: 0.06, blue: 0.12)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 按需加载并缓存背景照片，切换时避免重复读盘。
    private static var imageCache: [String: NSImage] = [:]
    private static let cacheLock = NSLock()

    private static func image(for photo: BackgroundPhoto) -> NSImage? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = imageCache[photo.rawValue] { return cached }
        guard let url = Bundle.main.url(
            forResource: "Background-\(photo.rawValue)",
            withExtension: "jpg"
        ), let image = NSImage(contentsOf: url) else {
            return nil
        }
        imageCache[photo.rawValue] = image
        return image
    }
}

enum AppearanceSetting {
    static let backgroundKey = "immersiveBackgroundEnabled"
}

private extension Double {
    static let circle = 2.0 * Double.pi
}
