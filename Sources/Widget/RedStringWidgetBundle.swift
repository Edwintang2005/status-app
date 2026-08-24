import SwiftUI
import WidgetKit

@main
struct RedStringWidgetBundle: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        NudgeWidget()
        MomentWidget()
    }
}
