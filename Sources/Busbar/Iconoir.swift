import AppKit
import SwiftUI

/// Icons from Iconoir (iconoir.com, MIT licence), kept as their SVG source so the app
/// needs no resource bundle. They draw as template images, so like SF Symbols they
/// take the foreground style.
enum Iconoir: CaseIterable {
    case sunLight, evPlugCharging, car, plugTypeA, plugTypeC, batteryIndicator
    case dotArrowUp, dotArrowDown, warningTriangleSolid, xmarkCircle

    /// The icon drawn `size` points square.
    @MainActor func image(size: CGFloat) -> some View {
        Image(nsImage: Self.images[self]!).resizable().frame(width: size, height: size)
    }

    @MainActor private static let images: [Iconoir: NSImage] = Dictionary(uniqueKeysWithValues: allCases.map { icon in
        let image = NSImage(data: Data(icon.svg.utf8))!
        image.isTemplate = true
        return (icon, image)
    })

    private var svg: String {
        switch self {
        case .sunLight: """
            <svg width="24" height="24" stroke-width="1.5" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M12 18C15.3137 18 18 15.3137 18 12C18 8.68629 15.3137 6 12 6C8.68629 6 6 8.68629 6 12C6 15.3137 8.68629 18 12 18Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M22 12L23 12" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M12 2V1" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M12 23V22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M20 20L19 19" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M20 4L19 5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M4 20L5 19" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M4 4L5 5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M1 12L2 12" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            """
        case .evPlugCharging: """
            <svg width="24" height="24" stroke-width="1.5" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M10 13.1538V21" stroke="currentColor" stroke-linecap="round"/>
            <path d="M15 8.38452V11.1538C15 12.2583 14.1046 13.1538 13 13.1538H7C5.89543 13.1538 5 12.2583 5 11.1538V8.38452C5 7.27995 5.89543 6.38452 7 6.38452H13C14.1046 6.38452 15 7.27995 15 8.38452Z" stroke="currentColor" stroke-linecap="round"/>
            <path d="M13.3334 6.38462V3" stroke="currentColor" stroke-linecap="round"/>
            <path d="M6.66663 6.38462V3" stroke="currentColor" stroke-linecap="round"/>
            <path d="M16.6667 16L15 19H19L17.3333 22" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            """
        case .car: """
            <svg width="24" height="24" stroke-width="1.5" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M8 10L16 10" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M7 14L8 14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M16 14L17 14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M3 18V11.4105C3 11.1397 3.05502 10.8716 3.16171 10.6227L5.4805 5.21216C5.79566 4.47679 6.51874 4 7.31879 4H16.6812C17.4813 4 18.2043 4.47679 18.5195 5.21216L20.8383 10.6227C20.945 10.8716 21 11.1397 21 11.4105V18M3 18V20.4C3 20.7314 3.26863 21 3.6 21H6.4C6.73137 21 7 20.7314 7 20.4V18M3 18H7M21 18V20.4C21 20.7314 20.7314 21 20.4 21H17.6C17.2686 21 17 20.7314 17 20.4V18M21 18H17M7 18H17" stroke="currentColor" stroke-width="1.5"/>
            </svg>
            """
        case .plugTypeA: """
            <svg width="24" height="24" stroke-width="1.5" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M9 10V14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M15 10V14" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            """
        case .plugTypeC: """
            <svg width="24" height="24" stroke-width="1.5" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M8 14C9.10457 14 10 13.1046 10 12C10 10.8954 9.10457 10 8 10C6.89543 10 6 10.8954 6 12C6 13.1046 6.89543 14 8 14Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M16 14C17.1046 14 18 13.1046 18 12C18 10.8954 17.1046 10 16 10C14.8954 10 14 10.8954 14 12C14 13.1046 14.8954 14 16 14Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            """
        case .batteryIndicator: """
            <svg width="24" height="24" stroke-width="1.5" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M14 13H16L18 13" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M6 13H8M10 13H8M8 13V11M8 13V15" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M6 7H2.6C2.26863 7 2 7.26863 2 7.6V18.4C2 18.7314 2.26863 19 2.6 19H21.4C21.7314 19 22 18.7314 22 18.4V7.6C22 7.26863 21.7314 7 21.4 7H18M6 7V5H8V7M6 7H8M8 7H16M16 7V5H18V7M16 7H18" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            """
        case .dotArrowUp: """
            <svg width="24" height="24" stroke-width="1.5" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M12 22C10.8954 22 10 21.1046 10 20C10 18.8954 10.8954 18 12 18C13.1046 18 14 18.8954 14 20C14 21.1046 13.1046 22 12 22Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M12 15L12 2M12 2L15 5M12 2L9 5" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            """
        case .dotArrowDown: """
            <svg width="24" height="24" stroke-width="1.5" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M12 6C10.8954 6 10 5.10457 10 4C10 2.89543 10.8954 2 12 2C13.1046 2 14 2.89543 14 4C14 5.10457 13.1046 6 12 6Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M12 9L12 22M12 22L15 19M12 22L9 19" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            """
        case .warningTriangleSolid: """
            <svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path fill-rule="evenodd" clip-rule="evenodd" d="M9.61617 3.6419C10.6736 1.80296 13.3268 1.80296 14.3841 3.6419L22.4271 17.6296C23.4813 19.463 22.1579 21.7504 20.0431 21.7504H3.95721C1.84242 21.7504 0.519055 19.463 1.57322 17.6296L9.61617 3.6419ZM12 8.25C12.4142 8.25 12.75 8.58579 12.75 9V13C12.75 13.4142 12.4142 13.75 12 13.75C11.5858 13.75 11.25 13.4142 11.25 13V9C11.25 8.58579 11.5858 8.25 12 8.25ZM12.5675 17.5008C12.8446 17.1929 12.8196 16.7187 12.5117 16.4416C12.2038 16.1645 11.7296 16.1894 11.4525 16.4973L11.4425 16.5084C11.1654 16.8163 11.1904 17.2905 11.4983 17.5676C11.8062 17.8447 12.2804 17.8197 12.5575 17.5119L12.5675 17.5008Z" fill="currentColor"/>
            </svg>
            """
        case .xmarkCircle: """
            <svg width="24" height="24" stroke-width="1.5" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg">
            <path d="M9.17218 14.8284L12.0006 12M14.829 9.17157L12.0006 12M12.0006 12L9.17218 9.17157M12.0006 12L14.829 14.8284" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            <path d="M12 22C17.5228 22 22 17.5228 22 12C22 6.47715 17.5228 2 12 2C6.47715 2 2 6.47715 2 12C2 17.5228 6.47715 22 12 22Z" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"/>
            </svg>
            """
        }
    }
}
