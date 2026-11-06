
import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var auth: ItchAuthService

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let user = auth.user {
                        HStack(spacing: 14) {
                            AsyncImage(url: user.coverUrl) { image in
                                image
                                    .resizable()
                                    .scaledToFill()
                            } placeholder: {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable()
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 5) {
                                Text(user.displayName ?? user.username)
                                    .font(.headline)

                                Text("@\(user.username)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)

                                Text("已连接 itch.io")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }

                            Spacer()
                        }
                        .padding(.vertical, 8)

                        if let url = user.url {
                            Link(
                                "打开 itch.io 个人主页",
                                destination: url
                            )
                        }

                        Button("退出登录", role: .destructive) {
                            Task {
                                await auth.signOut()
                            }
                        }
                    } else {
                        HStack(spacing: 14) {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 44))
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 5) {
                                Text("尚未登录")
                                    .font(.headline)

                                Text("连接 itch.io 以同步你的游戏库")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)

                        Button {
                            Task {
                                await auth.signIn()
                            }
                        } label: {
                            HStack {
                                Spacer()

                                if auth.isLoading {
                                    ProgressView()
                                } else {
                                    Label(
                                        "使用 itch.io 登录",
                                        systemImage: "person.crop.circle.badge.checkmark"
                                    )
                                }

                                Spacer()
                            }
                        }
                        .disabled(auth.isLoading)
                    }
                }

                if let error = auth.errorMessage {
                    Section("登录提示") {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
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
