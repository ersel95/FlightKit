//
//  BuildVersionInfo.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

struct BuildVersionInfo: Hashable {
    var marketingVersion: String
    var buildNumber: String
    var bundleIdentifier: String
    var teamId: String
    var productName: String
    var marketingVersionSourceFile: URL?
    var buildNumberSourceFile: URL?
}
