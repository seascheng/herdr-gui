import Foundation

enum QuickTerminalPosition: String {
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case center

    var isLeft: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }

    var isRight: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }

    var isTop: Bool {
        self == .top || self == .topLeft || self == .topRight
    }

    var isBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
}
