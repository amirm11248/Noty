import CoreText
import Foundation
import SwiftUI
import UIKit

/// Single source of truth for Noty's Notion-inspired visual language.
///
/// Studied from Notion's actual product (not the marketing site):
/// - App chrome is near-monochrome warm neutrals, color reserved for one blue action.
/// - Light mode: sidebar `#F7F6F3`, page `#FFFFFF`, ink `#37352F`,
///   secondary `#6F6E69`, hairline borders `rgba(55,53,47,0.09)`.
/// - In-app accent blue is `#2383E2` (links, selection, primary action).
/// - Cards are flat: 1px hairline border, 6-8pt radius, no shadows.
///   Only popovers/menus float with a soft shadow.
/// - Type is one sans family (Inter / system), small UI text (13-14pt),
///   tight large titles, uppercase 11pt micro-labels with tracking.
/// - Spacing runs on a 4pt base; rows are dense (28-32pt), pages breathe
///   inside a ~900pt max width.
/// - Dark mode: canvas `#191919`, sidebar `#202020`, ink near-white,
///   borders `rgba(255,255,255,0.09)`.
enum NotionTheme {
    // MARK: - Surfaces

    /// Warm paper behind the sidebar / page rails. Light `#F7F6F3`, dark `#202020`.
    static let sidebar = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.125, green: 0.125, blue: 0.125, alpha: 1) // #202020
            : UIColor(red: 0.968, green: 0.965, blue: 0.953, alpha: 1) // #F7F6F3
    })

    /// Main page floor. Pure white in light mode, `#191919` in dark mode.
    static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.098, green: 0.098, blue: 0.098, alpha: 1) // #191919
            : .white
    })

    /// Card / popover surface. White light, `#262626` dark.
    static let card = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.149, green: 0.149, blue: 0.149, alpha: 1)
            : .white
    })

    /// Hover / selected-row wash. Neutral gray, never blue.
    static let rowHover = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.06)
            : UIColor(red: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.06)
    })

    /// Pressed-row wash, one step darker than hover.
    static let rowPressed = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(red: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.10)
    })

    /// Callout / muted block fill (sync banners, empty states).
    static let callout = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.05)
            : UIColor(red: 0.968, green: 0.965, blue: 0.953, alpha: 1)
    })

    // MARK: - Ink

    /// Primary text. Warm charcoal `#37352F` light, `#EDEDED` dark (never pure black-on-white harshness).
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.93, green: 0.93, blue: 0.93, alpha: 1)
            : UIColor(red: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 1)
    })

    /// Secondary text `#6F6E69` light, gray dark.
    static let inkSecondary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.62, blue: 0.60, alpha: 1)
            : UIColor(red: 111 / 255, green: 110 / 255, blue: 105 / 255, alpha: 1)
    })

    /// Tertiary / placeholder text.
    static let inkTertiary = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.48, green: 0.48, blue: 0.47, alpha: 1)
            : UIColor(red: 155 / 255, green: 155 / 255, blue: 150 / 255, alpha: 1)
    })

    // MARK: - Lines & accent

    /// 1px hairline. `rgba(55,53,47,0.09)` light, `rgba(255,255,255,0.09)` dark.
    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.09)
            : UIColor(red: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.09)
    })

    /// Stronger hairline for card borders `rgba(55,53,47,0.16)`.
    static let borderStrong = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.16)
            : UIColor(red: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.16)
    })

    /// The single chromatic commitment: Notion in-app blue `#2383E2`.
    /// Reserved for primary actions, links, and selection rings.
    static let accent = Color(red: 35 / 255, green: 131 / 255, blue: 226 / 255)

    static let accentPressed = Color(red: 0 / 255, green: 91 / 255, blue: 171 / 255)

    static let danger = Color(red: 224 / 255, green: 49 / 255, blue: 49 / 255)

    // MARK: - Paper (editor page sheet)

    /// The writable page itself stays pure white like a Notion page.
    static let paper = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.149, green: 0.149, blue: 0.149, alpha: 1)
            : .white
    })

    /// Workspace around the page sheet — the warm canvas again.
    static let workspace = sidebar

    /// Ruled/grid/dot template ink: faint warm gray, not blue.
    static let templateLine = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(red: 55 / 255, green: 53 / 255, blue: 47 / 255, alpha: 0.12)
    })

    // MARK: - Metrics

    static let radiusSmall: CGFloat = 4
    static let radiusMedium: CGFloat = 6
    static let radiusCard: CGFloat = 8
    static let borderWidth: CGFloat = 1
    static let sidebarRowHeight: CGFloat = 32
    static let pageMaxWidth: CGFloat = 900

    // MARK: - Typography

    enum TypefaceWeight {
        case regular
        case medium
        case semibold
        case bold
    }

    /// Notion uses a tuned NotionInter build. Inter is the closest
    /// redistribution-safe match, so all chrome goes through one family.
    static func font(_ size: CGFloat, weight: TypefaceWeight = .regular) -> Font {
        let postScriptName: String
        switch weight {
        case .regular:
            postScriptName = "Inter-Regular"
        case .medium:
            postScriptName = "Inter-Medium"
        case .semibold:
            postScriptName = "Inter-SemiBold"
        case .bold:
            postScriptName = "Inter-Bold"
        }
        return .custom(postScriptName, size: size)
    }

    static let body = font(14)
    static let bodySmall = font(13)
    static let caption = font(12)
    static let captionSmall = font(11)
    static let control = font(13, weight: .medium)

    /// 14pt regular/medium — sidebar rows, database rows, buttons.
    static func uiText(_ size: CGFloat = 14, weight: TypefaceWeight = .regular) -> Font {
        font(size, weight: weight)
    }

    /// Notion page title: Inter Bold, compact and slightly tracked in.
    static let pageTitle = font(32, weight: .bold)

    /// Section micro-label: small Inter semibold with understated tracking.
    static let microLabel = font(11, weight: .semibold)

    static let microTracking: CGFloat = 0.45

    // MARK: - Shadows (used sparingly; cards use borders instead)

    /// Only floating layers (menus, popovers, sheets) get this.
    static let popoverShadow = Color.black.opacity(0.10)
}

// MARK: - Reusable Notion-style treatments

struct NotionCardModifier: ViewModifier {
    var radius: CGFloat = NotionTheme.radiusCard

    func body(content: Content) -> some View {
        content
            .background(NotionTheme.card, in: RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .stroke(NotionTheme.hairline, lineWidth: NotionTheme.borderWidth)
            }
    }
}

struct NotionCalloutModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(NotionTheme.callout, in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium))
            .overlay {
                RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
                    .stroke(NotionTheme.hairline, lineWidth: NotionTheme.borderWidth)
            }
    }
}

struct NotionSidebarRowModifier: ViewModifier {
    var isSelected: Bool

    func body(content: Content) -> some View {
        content
            .frame(minHeight: NotionTheme.sidebarRowHeight)
            .background(
                isSelected ? NotionTheme.rowHover : Color.clear,
                in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
            )
            .contentShape(RoundedRectangle(cornerRadius: NotionTheme.radiusMedium))
    }
}

extension View {
    /// Flat Notion card: white surface, 1px hairline, 8pt radius, no shadow.
    func notionCard(radius: CGFloat = NotionTheme.radiusCard) -> some View {
        modifier(NotionCardModifier(radius: radius))
    }

    /// Muted Notion callout block for banners and status rows.
    func notionCallout() -> some View {
        modifier(NotionCalloutModifier())
    }

    /// Dense 32pt sidebar row with neutral-gray selection (never blue).
    func notionSidebarRow(isSelected: Bool = false) -> some View {
        modifier(NotionSidebarRowModifier(isSelected: isSelected))
    }
}

/// Notion section header: `PAGES` / `FOLDERS` — 11pt semibold, wide tracking, tertiary ink.
struct NotionSectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(NotionTheme.microLabel)
            .tracking(NotionTheme.microTracking)
            .foregroundStyle(NotionTheme.inkTertiary)
    }
}

/// Ghost icon button: no pill fill, ink icon, gray hover wash. The Notion toolbar default.
struct NotionIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(NotionTheme.ink)
            .frame(width: 30, height: 30)
            .background(
                configuration.isPressed ? NotionTheme.rowPressed : Color.clear,
                in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
            )
            .contentShape(Rectangle())
    }
}

/// Quiet text button for editor toolbars: 13pt medium ink, gray wash when pressed.
struct NotionToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? NotionTheme.accent : NotionTheme.ink)
            .padding(.horizontal, 7)
            .frame(height: 30)
            .background(
                configuration.isPressed ? NotionTheme.rowHover : Color.clear,
                in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
            )
            .contentShape(Rectangle())
    }
}

/// The one blue action per screen: filled `#2383E2`, white text, 6pt radius.
struct NotionPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(NotionTheme.control)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                configuration.isPressed ? NotionTheme.accentPressed : NotionTheme.accent,
                in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
            )
    }
}


// MARK: - Navigation chrome

/// Flat row interaction used by Notion-style page and folder lists.
struct NotionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? NotionTheme.rowPressed : Color.clear,
                in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
            )
            .contentShape(Rectangle())
    }
}

/// Compact search treatment that lives inside the sidebar instead of using
/// Apple's large navigation search chrome.
struct NotionSearchField: View {
    @Binding var text: String
    var placeholder = "Search"

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(NotionTheme.inkSecondary)

            TextField(placeholder, text: $text)
                .font(NotionTheme.font(13))
                .foregroundStyle(NotionTheme.ink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .submitLabel(.search)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(NotionTheme.inkTertiary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(
            isFocused ? NotionTheme.rowPressed : NotionTheme.rowHover,
            in: RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
        )
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: NotionTheme.radiusMedium)
                    .stroke(NotionTheme.borderStrong, lineWidth: 0.75)
            }
        }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}


// MARK: - Font registration

/// Registers the Inter resources shipped by the pinned FontInter package
/// without importing its Swift module. This keeps Noty's existing
/// xcodebuild -target CI path working while still embedding the font resource.
enum NotionFontRegistrar {
    static func registerInter() {
        guard let resources = Bundle.main.resourceURL else { return }

        let fileManager = FileManager.default
        let topLevel = (try? fileManager.contentsOfDirectory(
            at: resources,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidateBundles = topLevel.filter {
            $0.pathExtension == "bundle" &&
            $0.lastPathComponent.localizedCaseInsensitiveContains("FontInter")
        }

        for bundleURL in candidateBundles {
            guard let fontBundle = Bundle(url: bundleURL) else { continue }
            let fontURLs = fontBundle.urls(forResourcesWithExtension: "ttf", subdirectory: nil) ?? []
            for url in fontURLs {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}
