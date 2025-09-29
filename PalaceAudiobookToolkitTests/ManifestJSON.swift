//
//  ManifestJSON.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 5/23/24.
//  Copyright © 2024 The Palace Project. All rights reserved.
//

import Foundation

extension Manifest {
  static func from(jsonFileName: String, bundle: Bundle = .main) throws -> Manifest {
    guard let url = bundle.url(forResource: jsonFileName, withExtension: "json"),
          let jsonData = try? Data(contentsOf: url)
    else {
      throw NSError(
        domain: "ManifestLoadingError",
        code: 404,
        userInfo: [NSLocalizedDescriptionKey: "Failed to load \(jsonFileName).json"]
      )
    }

    let decoder = Manifest.customDecoder()
    return try decoder.decode(Manifest.self, from: jsonData)
  }
}

// MARK: - ManifestJSON

enum ManifestJSON: String, CaseIterable {
  case alice = "alice_manifest"
  case anathem = "anathem_manifest"
  case animalFarm = "animalFarm_manifest"
  case bigFail = "theBigFail_manifest"
  case bocas = "bocas_manifest"
  case christmasCarol = "christmas_carol_manifest"
  case flatland = "flatland_manifest"
  case bestNewHorror = "best_new_horror_manifest"
  case quickSilver = "quicksilver_manifest"
  case littleWomenDevotional = "littleWomenDevotional_manifest"
  case martian = "the_martian_manifest"
  case snowcrash = "snowcrash_manifest"
  case secretLives = "secret_lives_manifest"
  case theSystemOfTheWorld = "the_system_of_the_world_manifest"
  case endOfTheWorld = "endOfTheWorld_manifest"
  case whereTheLineIsDrawn = "where_the_line_is_drawn_manifest"

  var chapterCount: Int {
    switch self {
    case .alice: 13
    case .anathem: 17
    case .animalFarm: 3
    case .bigFail: 22
    case .bocas: 14
    case .christmasCarol: 6
    case .flatland: 25
    case .littleWomenDevotional: 54
    case .martian: 41
    case .bestNewHorror: 7
    case .quickSilver: 29
    case .snowcrash: 72
    case .secretLives: 10
    case .theSystemOfTheWorld: 47
    case .endOfTheWorld: 14
    case .whereTheLineIsDrawn: 14
    }
  }

  var chapterDurations: [Double] {
    switch self {
    case .bigFail:
      [
        15.0, 7.0, 586.0, 3061.0, 2740.0, 2177.0, 2395.0, 2230.0, 4218.0,
        1991.0, 2830.0, 1533.0, 2811.0, 1752.0, 2367.0, 2863.0, 3025.0,
        2596.0, 2296.0, 3019.0, 2006.0, 36.0
      ]
    case .snowcrash:
      [
        75.0, 1388.0, 955.0, 1146.0, 1161.0, 1158.0, 1278.0, 1196.0, 699.0,
        945.0, 961.0, 538.0, 1621.0, 1214.0, 1411.0, 1089.0, 1054.0, 884.0,
        591.0, 1267.0, 535.0, 1102.0, 806.0, 786.0, 1157.0, 787.0, 837.0, 1084.0,
        799.0, 1006.0, 1046.0, 882.0, 988.0, 1199.0, 1066.0, 584.0, 1133.0, 1214.0,
        470.0, 1110.0, 668.0, 1234.0, 656.0, 808.0, 937.0, 686.0, 350.0, 691.0,
        1197.0, 1321.0, 494.0, 1017.0, 1018.0, 743.0, 68.0, 522.0, 1232.0, 738.0,
        883.0, 528.0, 910.0, 666.0, 105.0, 720.0, 186.0, 653.0, 560.0, 642.0,
        532.0, 656.0, 461.0, 323.0
      ]
    case .quickSilver:
      [
        125.0, 3.0, 3435.0, 1680.0, 2738.0, 2000.0, 1141.0, 552.0, 157.0, 309.0,
        1002.0, 1270.0, 378.0, 3248.0, 5413.0, 460.0, 2028.0, 781.0, 2413.0, 5518.0,
        723.0, 2281.0, 3556.0, 2944.0, 511.0, 2885.0, 806.0, 3918.0, 751.0
      ]
    default:
      []
    }
  }

  var chapterOffset: [Int] {
    switch self {
    case .snowcrash:
      [
        0, 75, 1463, 2418, 626, 1787, 12, 1290, 2486, 326, 1271, 2232, 13, 1634, 13,
        1424, 2513, 768, 1652, 2243, 939, 1474, 15, 821, 1607, 280, 1067, 1904, 686,
        1485, 17, 1063, 18, 1006, 2205, 751, 1335, 19, 1233, 1703, 19, 687, 1921, 20,
        828, 1765, 20, 370, 1061, 20, 1341, 1835, 21, 1039, 1782, 1850, 21, 1253, 1991,
        21, 549, 1459, 2125, 2230, 398, 584, 1237, 1797, 22, 554, 1210, 1671
      ]
    default:
      []
    }
  }
}
