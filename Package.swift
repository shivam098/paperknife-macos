// swift-tools-version: 5.9
import PackageDescription

// PDFium (chromium/8152, the universal build without V8 or XFA) is downloaded by
// scripts/fetch-pdfium.sh, which checks its checksum; it isn't committed.
let pdfiumLibrary = Context.packageDirectory + "/third_party/pdfium/mac/lib"

let package = Package(
    name: "PaperKnife",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PaperKnifeCore", targets: ["PaperKnifeCore"]),
        .executable(name: "PaperKnife", targets: ["PaperKnifeApp"]),
    ],
    targets: [
        // PDFium's C API. The tests find the library where the script put it; the app finds it in
        // its bundle's Frameworks folder (see scripts/package-app.sh).
        .target(
            name: "CPDFium",
            linkerSettings: [
                .linkedLibrary("pdfium"),
                .unsafeFlags(["-L\(pdfiumLibrary)", "-Xlinker", "-rpath", "-Xlinker", pdfiumLibrary]),
            ]),
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "PaperKnifeCore", dependencies: ["CPDFium", "CZlib"]),
        .executableTarget(
            name: "PaperKnifeApp",
            dependencies: ["PaperKnifeCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "PaperKnifeCoreTests", dependencies: ["PaperKnifeCore"]),
        .testTarget(name: "PaperKnifeAppTests", dependencies: ["PaperKnifeApp"]),
    ]
)
