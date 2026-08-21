import CoreGraphics
import Foundation
import GhosttyKit

/// Represents the Ghostty `quick-terminal-size` configuration.
struct QuickTerminalSize {
    let primary: Size?
    let secondary: Size?

    init(primary: Size? = nil, secondary: Size? = nil) {
        self.primary = primary
        self.secondary = secondary
    }

    init(from cStruct: ghostty_config_quick_terminal_size_s) {
        self.primary = Size(from: cStruct.primary)
        self.secondary = Size(from: cStruct.secondary)
    }

    enum Size {
        case percentage(Double)
        case pixels(UInt32)

        init(from cStruct: ghostty_quick_terminal_size_s) {
            switch cStruct.tag {
            case GHOSTTY_QUICK_TERMINAL_SIZE_NONE:
                self = .pixels(0)
            case GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE:
                self = .percentage(Double(cStruct.value.percentage))
            case GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS:
                self = .pixels(cStruct.value.pixels)
            default:
                self = .pixels(0)
            }
        }

        init?(_ cStruct: ghostty_quick_terminal_size_s) {
            switch cStruct.tag {
            case GHOSTTY_QUICK_TERMINAL_SIZE_NONE:
                return nil
            case GHOSTTY_QUICK_TERMINAL_SIZE_PERCENTAGE:
                self = .percentage(Double(cStruct.value.percentage))
            case GHOSTTY_QUICK_TERMINAL_SIZE_PIXELS:
                self = .pixels(cStruct.value.pixels)
            default:
                return nil
            }
        }

        func toPixels(parentDimension: CGFloat) -> CGFloat {
            switch self {
            case .percentage(let value):
                return parentDimension * CGFloat(value) / 100.0
            case .pixels(let value):
                return CGFloat(value)
            }
        }
    }

    func calculate(position: QuickTerminalPosition, screenDimensions: CGSize) -> CGSize {
        let dims = CGSize(width: screenDimensions.width, height: screenDimensions.height)

        switch position {
        case .left, .right:
            return CGSize(
                width: primary?.toPixels(parentDimension: dims.width) ?? 400,
                height: secondary?.toPixels(parentDimension: dims.height) ?? dims.height
            )
        default:
            if dims.width >= dims.height {
                return CGSize(
                    width: primary?.toPixels(parentDimension: dims.width) ?? 800,
                    height: secondary?.toPixels(parentDimension: dims.height) ?? 400
                )
            } else {
                return CGSize(
                    width: secondary?.toPixels(parentDimension: dims.width) ?? 400,
                    height: primary?.toPixels(parentDimension: dims.height) ?? 800
                )
            }
        }
    }
}
