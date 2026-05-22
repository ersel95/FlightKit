//
//  ASCCredentials.swift
//  FlightKit
//
//  Created by Mr. t.
//

import Foundation

struct ASCCredentials: Codable, Hashable {
    let keyId: String
    let issuerId: String
    let privateKeyPEM: String

    var p8FileName: String { "AuthKey_\(keyId).p8" }
}
