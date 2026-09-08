// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BibliotecaMacWeb",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BibliotecaMacWeb",
            path: "Sources/BibliotecaMacWeb",
            resources: [.copy("Resources/biblioteca.html")]
        )
    ]
)
