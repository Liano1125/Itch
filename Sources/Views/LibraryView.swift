import SwiftUI

struct LibraryView: View {
    var body: some View {
        NavigationStack {
            ContentPlaceholder(
                symbol: "books.vertical",
                title: "你的游戏库",
                message: "登录 itch.io 后，这里会显示你拥有或领取的游戏。"
            )
            .padding()
            .navigationTitle("游戏库")
        }
    }
}
