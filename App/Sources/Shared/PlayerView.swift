import SwiftUI
import VLCKit

/// Plays a stream from the local streaming server.
///
/// VLCKit rather than AVPlayer because torrents are mostly MKV, AVI and other
/// containers AVFoundation will not open; a player that fails on the common
/// case is not much of a player.
struct PlayerView: View {
    let url: URL
    let title: String

    @State private var player = VLCMediaPlayer()
    @State private var isPlaying = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            VideoSurface(player: player)
                .background(.black)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)

            HStack(spacing: 16) {
                Button {
                    isPlaying.toggle()
                    isPlaying ? player.play() : player.pause()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)

                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
        }
        .onAppear {
            // The server streams from 127.0.0.1 and blocks until the pieces the
            // player needs have arrived, so playback can start before the
            // download finishes.
            player.media = VLCMedia(url: url)
            player.play()
        }
        .onDisappear {
            player.stop()
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 420)
        #endif
    }
}

/// Bridges VLCKit's platform view into SwiftUI.
#if os(macOS)
private struct VideoSurface: NSViewRepresentable {
    let player: VLCMediaPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        player.drawable = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
#else
private struct VideoSurface: UIViewRepresentable {
    let player: VLCMediaPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.drawable = view
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
