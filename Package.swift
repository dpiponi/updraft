// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdraftCLIViewer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "updraft", targets: ["UpdraftCLIViewer"])
    ],
    targets: [
        .executableTarget(
            name: "UpdraftCLIViewer",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("PDFKit")
            ]
        )
    ]
)
