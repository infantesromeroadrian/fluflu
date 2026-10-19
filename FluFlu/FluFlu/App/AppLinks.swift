import Foundation

/// Enlaces públicos de FluFlu. La política de privacidad tiene que ser accesible desde la app y desde
/// la ficha de la Mac App Store (guideline 5.1.1(i)); vive en el repositorio para tener una URL estable.
nonisolated enum AppLinks {
    static let privacyPolicy = URL(string: "https://github.com/infantesromeroadrian/fluflu/blob/main/PRIVACY.md")!
}
