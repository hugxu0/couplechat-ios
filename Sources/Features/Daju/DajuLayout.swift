import Foundation

enum DajuLayoutMode: Equatable {
    case stacked
    case split
}

struct DajuLayoutMetrics: Equatable {
    let mode: DajuLayoutMode
    let totalContentWidth: CGFloat
    let sceneWidth: CGFloat
    let panelWidth: CGFloat
    let stackedSceneHeight: CGFloat

    static func resolve(
        width: CGFloat,
        height: CGFloat,
        hasRegularHorizontalSizeClass: Bool
    ) -> DajuLayoutMetrics {
        let usesSplit = hasRegularHorizontalSizeClass && width >= 900
        guard usesSplit else {
            let minimumSceneHeight = height < 650 ? max(180, height * 0.50) : 300
            return DajuLayoutMetrics(
                mode: .stacked,
                totalContentWidth: width,
                sceneWidth: width,
                panelWidth: width,
                stackedSceneHeight: min(max(height * 0.43, minimumSceneHeight), 430))
        }
        let total = min(width, 1_050)
        let panel = min(max(total * 0.40, 360), 420)
        return DajuLayoutMetrics(
            mode: .split,
            totalContentWidth: total,
            sceneWidth: total - panel - 14,
            panelWidth: panel,
            stackedSceneHeight: 0)
    }
}
