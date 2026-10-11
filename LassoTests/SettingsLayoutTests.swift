import Testing
import AppKit
import SwiftUI
@testable import Lasso

/// A model picker with `.fixedSize()` took its label's full width, so a long MLX model id made the
/// Intelligence form wider than the window and pushed it past the left edge (no left padding, the
/// row's "Model" label gone).
@MainActor
struct SettingsLayoutTests {
    private let longID = "TheCluster/Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-MLX-mxfp4"

    private func formWidth<Control: View>(_ control: Control, in width: CGFloat) -> CGFloat {
        let form = Form {
            Section("Language model") { HStack { Text("Model"); Spacer(); control } }
        }.formStyle(.grouped)
        return NSHostingController(rootView: form).sizeThatFits(in: CGSize(width: width, height: 400)).width
    }

    @Test func aLongModelIDFitsTheWindow() {
        let menu = Menu { Button("x") {} } label: { Text(longID) }
        #expect(formWidth(menu.fixedSize(), in: 520) > 520, "baseline: the old sizing overflows")
        #expect(formWidth(menu.settingsCappedMenu(), in: 520) <= 520)
    }
}
