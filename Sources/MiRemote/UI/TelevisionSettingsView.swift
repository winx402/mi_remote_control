import SwiftUI

@MainActor
struct TelevisionSettingsView: View {
    @Binding var configuration: XiaomiTVConfiguration?
    @Binding var volumeKeysControlTV: Bool
    @ObservedObject private var television = XiaomiTVController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("启用小米电视联动", isOn: Binding(
                get: { configuration?.enabled == true },
                set: { enabled in
                    var value = configuration ?? XiaomiTVConfiguration()
                    value.enabled = enabled
                    configuration = value
                }))
            if configuration?.enabled == true {
                TextField("电视局域网 IP", text: Binding(
                    get: { configuration?.host ?? "" },
                    set: { host in
                        var value = configuration ?? XiaomiTVConfiguration()
                        value.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
                        configuration = value
                    }))
                    .textFieldStyle(.roundedBorder)
                Toggle("遥控器音量键控制小米电视", isOn: $volumeKeysControlTV)
                Text("关闭此项时，音量键控制 Mac。电源键打开电视、Mac 与应用操作面板。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("检查连接") {
                        ActionRunner.configureTelevision(configuration)
                        television.checkConnection { _ in }
                    }
                    Text(television.status)
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("电源键会先尝试唤醒电视，再打开面板；电视关机与待机是独立功能。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
