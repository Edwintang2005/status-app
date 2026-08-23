import SwiftUI
import WidgetKit

@main
struct TetherWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        NudgeWidget()
        MomentWidget()
    }
}
