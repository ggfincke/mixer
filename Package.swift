// swift-tools-version: 6.0
// Package.swift
// swiftpm manifest for the mixer menu bar app

import PackageDescription

let package = Package(
    name: "Mixer",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "Mixer"),
    ]
)
