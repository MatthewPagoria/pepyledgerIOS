// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "pepyledgerIOS",
  platforms: [
    .iOS(.v16)
  ],
  products: [
    .library(name: "Domain", targets: ["Domain"]),
    .library(name: "Data", targets: ["Data"]),
    .library(name: "Features", targets: ["Features"]),
    .library(name: "Services", targets: ["Services"]),
    .library(name: "UI", targets: ["UI"])
  ],
  dependencies: [
    .package(url: "https://github.com/auth0/Auth0.swift", from: "2.15.0"),
    .package(url: "https://github.com/RevenueCat/purchases-ios-spm.git", from: "5.9.0"),
    .package(url: "https://github.com/OneSignal/OneSignal-iOS-SDK", from: "5.2.0"),
    .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0")
  ],
  targets: [
    .target(
      name: "Domain",
      path: "Domain"
    ),
    .target(
      name: "Data",
      dependencies: [
        "Domain",
        .product(name: "GRDB", package: "GRDB.swift")
      ],
      path: "Data"
    ),
    .target(
      name: "Services",
      dependencies: [
        "Domain",
        .product(name: "Auth0", package: "Auth0.swift"),
        .product(name: "RevenueCat", package: "purchases-ios-spm"),
        .product(name: "OneSignalFramework", package: "OneSignal-iOS-SDK")
      ],
      path: "Services"
    ),
    .target(
      name: "UI",
      path: "UI"
    ),
    .target(
      name: "Features",
      dependencies: ["Domain", "Services", "UI"],
      path: "Features"
    ),
    .testTarget(
      name: "DataTests",
      dependencies: ["Data", "Domain"],
      path: "Tests/DataTests"
    )
  ]
)
