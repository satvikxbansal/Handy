import Foundation
import CoreGraphics

struct HandyScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let screenshotWidthPx: Int
    let screenshotHeightPx: Int
    let displayWidthPts: CGFloat
    let displayHeightPts: CGFloat
    let displayFrame: CGRect
}
