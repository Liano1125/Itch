import SwiftUI

struct ProfileView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("尚未登录")
                                .font(.headline)
                            Text("连接 itch.io 以同步你的游戏库")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                }

                Section("设置") {
                    Label("下载设置", systemImage: "arrow.down.to.line")
                    Label("存储空间", systemImage: "internaldrive")
                    Label("关于 itchPocket", systemImage: "info.circle")
                }
            }
            .navigationTitle("我的")
        }
    }
}
