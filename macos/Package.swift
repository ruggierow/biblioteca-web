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
        ),
        // So as duas funcoes que mexem em ARQUIVO. O pacote do Xcode
        // (project.yml) nao enxerga esta pasta, entao o aplicativo distribuido
        // nao muda de tamanho nem de conteudo por causa dos testes.
        .testTarget(
            name: "BibliotecaMacWebTests",
            dependencies: ["BibliotecaMacWeb"],
            path: "Tests/BibliotecaMacWebTests"
        )
    ]
)
