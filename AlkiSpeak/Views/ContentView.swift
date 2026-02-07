import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            WoadieBackground()

            VStack(spacing: 18) {
                WoadieHeaderView(model: model)
                WoadieControlsBar(model: model)
                WoadiePlaybackPanel(isPlaying: model.playingId != nil, onStop: model.stopPlayback)
                WoadieInputRow(model: model)

                if !model.message.isEmpty {
                    Text(model.message)
                        .font(WoadieTheme.mono(size: 11, weight: .medium))
                        .foregroundStyle(WoadieTheme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }

                SpeechLogView(
                    entries: model.chatItems,
                    playingId: model.playingId,
                    onReplay: { model.replay(item: $0) }
                )

                WoadieFooter()
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 820, minHeight: 720)
        .preferredColorScheme(.dark)
        .tint(WoadieTheme.primary)
        .alert("Port In Use", isPresented: $model.showPortInUseAlert) {
            Button("Switch and Start") {
                model.confirmPortSwitchAndStart()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Port 7777 is already in use. Switch to this engine by stopping the existing service?")
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
