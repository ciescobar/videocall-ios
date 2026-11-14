// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "VideoCall",
    platforms: [.iOS("17.0")],
    products: [.iOSApplication(
        name: "VideoCall", targets: ["AppModule"],
        bundleIdentifier: "com.mitech.videocall.applelab",
        displayVersion: "0.1.2", bundleVersion: "3",
        appIcon: .placeholder(icon: .camera), accentColor: .presetColor(.green),
        supportedDeviceFamilies: [.pad, .phone],
        supportedInterfaceOrientations: [.portrait, .landscapeRight, .landscapeLeft,
            .portraitUpsideDown(.when(deviceFamilies: [.pad]))],
        capabilities: [.camera(purposeString: "Registro facial local y videollamadas."),
            .microphone(purposeString: "Audio de tus llamadas con otros dispositivos.")]
    )],
    dependencies: [
        .package(url: "https://github.com/stasel/WebRTC", exact: "154.0.0")
    ],
    targets: [.executableTarget(name: "AppModule", dependencies: [
        .product(name: "WebRTC", package: "WebRTC"),
        "onnxruntime"
    ], path: "Sources", resources: [.process("Resources")],
       linkerSettings: [.linkedLibrary("c++"), .linkedFramework("Accelerate")]),
       .binaryTarget(name: "onnxruntime", path: "Frameworks/onnxruntime.xcframework")],
    swiftLanguageVersions: [.v5]
)
