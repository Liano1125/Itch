import SwiftUI

struct ProfileView: View {
    @EnvironmentObject private var auth: ItchAuthService

    private let accent = Color(red: 0.94, green: 0.31, blue: 0.34)

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    accountCard

                    if let error = auth.errorMessage {
                        Label {
                            Text(error)
                                .font(.footnote)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                    }

                    settingsSection
                    aboutSection
                }
                .padding(20)
                .padding(.bottom, 24)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private var accountCard: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("ITCH.IO ACCOUNT")
                    .font(.caption.weight(.heavy))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)

                Spacer()

                Circle()
                    .fill(auth.user == nil ? Color.secondary.opacity(0.5) : Color.green)
                    .frame(width: 7, height: 7)

                Text(auth.user == nil ? "未连接" : "已连接")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if let user = auth.user {
                HStack(spacing: 14) {
                    AsyncImage(url: user.coverUrl) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable()
                            .foregroundStyle(.secondary)
                    }
                    .frame(width: 62, height: 62)
                    .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 5) {
                        Text(user.displayName ?? user.username)
                            .font(.title3.bold())
                            .foregroundStyle(.primary)
                        Text("@\(user.username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                if let url = user.url {
                    Link(destination: url) {
                        Label("打开 itch.io 个人主页", systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }

                Button(role: .destructive) {
                    Task { await auth.signOut() }
                } label: {
                    Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 2)
            } else {
                HStack(spacing: 14) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("连接你的 itch.io 账号")
                            .font(.headline)
                        Text("登录后可读取账号资料与公开合集")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Button {
                    Task { await auth.signIn() }
                } label: {
                    HStack {
                        Spacer()
                        if auth.isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Label("使用 itch.io 登录", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.subheadline.weight(.semibold))
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 14)
                    .background(accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .disabled(auth.isLoading)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("偏好设置")
                .font(.title3.bold())

            VStack(spacing: 0) {
                settingsRow("外观", subtitle: "跟随 iOS 系统设置", symbol: "circle.lefthalf.filled")
                Divider().padding(.leading, 54)
                settingsRow("隐私与数据", subtitle: "了解 itchPocket 如何使用数据", symbol: "hand.raised")
            }
            .padding(.horizontal, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("关于")
                .font(.title3.bold())

            HStack(spacing: 12) {
                Image(systemName: "gamecontroller.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                    .frame(width: 42, height: 42)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

                VStack(alignment: .leading, spacing: 4) {
                    Text("itchPocket")
                        .font(.subheadline.weight(.semibold))
                    Text("为独立游戏爱好者打造的 iOS 客户端")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private func settingsRow(_ title: String, subtitle: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(accent)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 13)
    }
}
