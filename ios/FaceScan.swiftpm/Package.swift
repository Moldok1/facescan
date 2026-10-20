// swift-tools-version: 5.9

// FaceScan — scanner facial 3D par caméra TrueDepth (iPhone / iPad Pro avec Face ID).
// Projet « App Playground » : s'ouvre directement dans Xcode (ou Swift Playgrounds sur iPad).

import PackageDescription
import AppleProductTypes

let package = Package(
    name: "FaceScan",
    platforms: [
        .iOS("17.0")
    ],
    products: [
        .iOSApplication(
            name: "FaceScan",
            targets: ["AppModule"],
            bundleIdentifier: "fr.altiore.facescan",
            teamIdentifier: "",
            displayVersion: "0.1",
            bundleVersion: "1",
            appIcon: .placeholder(icon: .camera),
            accentColor: .presetColor(.teal),
            supportedDeviceFamilies: [
                .pad,
                .phone
            ],
            supportedInterfaceOrientations: [
                .portrait
            ],
            capabilities: [
                .camera(purposeString: "La caméra TrueDepth est utilisée pour scanner le visage du patient en 3D. Les données restent sur l'appareil.")
            ],
            appCategory: .medical
        )
    ],
    targets: [
        .executableTarget(
            name: "AppModule",
            path: "."
        )
    ]
)
