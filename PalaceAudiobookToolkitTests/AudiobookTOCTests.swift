//
//  AudiobookTOCTests.swift
//  PalaceAudiobookToolkitTests
//
//  Created by Maurice Carrier on 4/5/22.
//  Copyright © 2022 The Palace Project. All rights reserved.
//

import XCTest
@testable import PalaceAudiobookToolkit

class AudiobookTOCTests: XCTestCase {

    struct TestOutcome {
        var chapter: UInt
        var offset: Double
        var duration: Double
        var mediaType: LCPSpineElementMediaType
    }

    var tocManifestExpectedResults = [
        TestOutcome(chapter: UInt(0), offset: 71.0, duration: 9.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 80.0, duration: 335.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 415.0, duration: 374.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 789.0, duration: 600.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 18.0, duration: 864.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 882.0, duration: 804.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 17.0, duration: 931.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(7), offset: 948.0, duration: 575.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(8), offset: 17.0, duration: 448.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(9), offset: 465.0, duration: 659.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(10), offset: 1124.0, duration: 691.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(11), offset: 17.0, duration: 435.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(12), offset: 452.0, duration: 790.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(13), offset: 17.0, duration: 8.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(14), offset: 25.0, duration: 777.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(15), offset: 802.0, duration: 1421.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(16), offset: 564.0, duration: 0.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(17), offset: 564.0, duration: 1164.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(18), offset: 1728.0, duration: 374.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(19), offset: 16.0, duration: 965.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(20), offset: 981.0, duration: 1117.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(21), offset: 2098.0, duration: 582.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(22), offset: 18.0, duration: 437.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(23), offset: 455.0, duration: 722.0, mediaType: .audioMPEG)

    ]

    var nonTocManifestExpectedResults = [
        TestOutcome(chapter: UInt(0), offset: 0.0, duration: 487.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 0.0, duration: 437.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 0.0, duration: 364.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 0.0, duration: 299.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 0.0, duration: 668.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 0.0, duration: 626.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 0.0, duration: 539.0, mediaType: .audioMPEG)
    ]
    
    var martianManifestExpectedResult = [
        TestOutcome(chapter: UInt(0), offset: 0.0, duration: 28.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 28.0, duration: 1, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 29.0, duration: 782.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 2.0, duration: 2.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 4.0, duration: 335.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 339.0, duration: 179.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 518.0, duration: 7.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(7), offset: 525.0, duration: 231.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(8), offset: 756.0, duration: 66.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(9), offset: 822.0, duration: 151.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(10), offset: 973.0, duration: 122.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(11), offset: 3.0, duration: 2.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(12), offset: 5.0, duration: 300.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(13), offset: 305.0, duration: 180.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(14), offset: 485.0, duration: 206.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(15), offset: 691.0, duration: 387.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(16), offset: 3.0, duration: 2.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(17), offset: 5.0, duration: 208.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(18), offset: 213.0, duration: 131.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(19), offset: 344.0, duration: 302.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(20), offset: 646.0, duration: 110.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(21), offset: 756.0, duration: 264.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(22), offset: 4.0, duration: 2.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(23), offset: 6.0, duration: 158.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(24), offset: 164.0, duration: 10.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(25), offset: 174.0, duration: 110.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(26), offset: 284.0, duration: 536.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(27), offset: 820.0, duration: 312.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(28), offset: 1132.0, duration: 105.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(29), offset: 5.0, duration: 1509.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(30), offset: 1514.0, duration: 13.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(31), offset: 6.0, duration: 3.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(32), offset: 9.0, duration: 356.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(33), offset: 365.0, duration: 183.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(34), offset: 548.0, duration: 187.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(35), offset: 735.0, duration: 57.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(36), offset: 792.0, duration: 118.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(37), offset: 910.0, duration: 234.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(38), offset: 1144.0, duration: 211.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(39), offset: 1355.0, duration: 117.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(40), offset: 1472.0, duration: 222.0, mediaType: .audioMPEG)
    ]
    
    var snowCrashManifestExpectedResult = [
        TestOutcome(chapter: UInt(0), offset: 0.0, duration: 75.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 75.0, duration: 1388.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 1463.0, duration: 955.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 2418.0, duration: 1146.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 626.0, duration: 1161.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 1787.0, duration: 1158.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 12.0, duration: 1278.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(7), offset: 1290.0, duration: 1196.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(8), offset: 2486.0, duration: 699.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(9), offset: 326.0, duration: 945.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(10), offset: 1271.0, duration: 961.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(11), offset: 2232.0, duration: 538.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(12), offset: 13.0, duration: 1621.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(13), offset: 1634.0, duration: 1214.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(14), offset: 13.0, duration: 1411.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(15), offset: 1424.0, duration: 1089.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(16), offset: 2513.0, duration: 1054.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(17), offset: 768.0, duration: 884.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(18), offset: 1652.0, duration: 591.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(19), offset: 2243.0, duration: 1267.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(20), offset: 939.0, duration: 535.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(21), offset: 1474.0, duration: 1102.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(22), offset: 15.0, duration: 806.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(23), offset: 821.0, duration: 786.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(24), offset: 1607.0, duration: 1157.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(25), offset: 280.0, duration: 787.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(26), offset: 1067.0, duration: 837.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(27), offset: 1904.0, duration: 1084.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(28), offset: 686.0, duration: 799.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(29), offset: 1485.0, duration: 1006.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(30), offset: 17.0, duration: 1046.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(31), offset: 1063.0, duration: 882.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(32), offset: 18.0, duration: 988.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(33), offset: 1006.0, duration: 1199.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(34), offset: 2205.0, duration: 1066.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(35), offset: 751.0, duration: 584.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(36), offset: 1335.0, duration: 1133.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(37), offset: 19.0, duration: 1214.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(38), offset: 1233.0, duration: 470.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(39), offset: 1703.0, duration: 1110.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(40), offset: 19.0, duration: 668.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(41), offset: 687.0, duration: 1234.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(42), offset: 1921.0, duration: 656.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(43), offset: 20.0, duration: 808.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(44), offset: 828.0, duration: 937.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(45), offset: 1765.0, duration: 686.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(46), offset: 20.0, duration: 350.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(47), offset: 370.0, duration: 691.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(48), offset: 1061.0, duration: 1197.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(49), offset: 20.0, duration: 1321.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(50), offset: 1341.0, duration: 494.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(51), offset: 1835.0, duration: 1017.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(52), offset: 21.0, duration: 1018.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(53), offset: 1039.0, duration: 743.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(54), offset: 1782.0, duration: 68.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(55), offset: 1850.0, duration: 522.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(56), offset: 21.0, duration: 1232.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(57), offset: 1253.0, duration: 738.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(58), offset: 1991.0, duration: 883.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(59), offset: 21.0, duration: 528.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(60), offset: 549.0, duration: 910.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(61), offset: 1459.0, duration: 666.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(62), offset: 2125.0, duration: 105.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(63), offset: 2230.0, duration: 720.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(64), offset: 398.0, duration: 186.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(65), offset: 584.0, duration: 653.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(66), offset: 1237.0, duration: 560.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(67), offset: 1797.0, duration: 642.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(68), offset: 22.0, duration: 532.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(69), offset: 554.0, duration: 656.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(70), offset: 1210.0, duration: 461.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(71), offset: 1671.0, duration: 323.0, mediaType: .audioMPEG),
    ]
    
    var christmasCarolManifestExpectedResults = [
        TestOutcome(chapter: UInt(0), offset: 0.0, duration: 76.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 76.0, duration: 2982.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 3058.0, duration: 2649.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 2647.0, duration: 3598.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 3594.0, duration: 2375.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 2370.0, duration: 1026.0, mediaType: .audioMPEG)
    ]

    var anathemManifestExpectedResults = [
        TestOutcome(chapter: UInt(0), offset: 0.0, duration: 57.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 57.0, duration: 38.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 95.0, duration: 641.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 2.0, duration: 6908.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 6.0, duration: 13428.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 11.0, duration: 3879.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 12.0, duration: 6275.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(7), offset: 14.0, duration: 9684.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(8), offset: 43.0, duration: 9865.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(9), offset: 19.0, duration: 15743.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(10), offset: 22.0, duration: 8391.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(11), offset: 24.0, duration: 6339.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(12), offset: 25.0, duration: 13220.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(13), offset: 28.0, duration: 15100.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(14), offset: 31.0, duration: 5526.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(15), offset: 32.0, duration: 1574.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(16), offset: 1606.0, duration: 64.0, mediaType: .audioMPEG)
    ]

    var theSystemOfTheWorldManifestExpectedResults = [
        TestOutcome(chapter: UInt(0), offset: 0.0, duration: 131.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(1), offset: 2.0, duration: 1393, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(2), offset: 2.0, duration: 645.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(3), offset: 3.0, duration: 651.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(4), offset: 3.0, duration: 1011.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(5), offset: 4.0, duration: 2952.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(6), offset: 4.0, duration: 4388.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(7), offset: 5.0, duration: 713.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(8), offset: 6.0, duration: 1838.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(9), offset: 6.0, duration: 820.0, mediaType: .audioMPEG)
    ]
    
    var quicksilverManifestExpectedResults = [
            TestOutcome(chapter: UInt(0), offset: 0.0, duration: 125.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(1), offset: 2.0, duration: 3.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(2), offset: 5.0, duration: 3435.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(3), offset: 1.0, duration: 1680.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(4), offset: 0.0, duration: 2738.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(5), offset: 2738.0, duration: 2000.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(6), offset: 1999.0, duration: 1141.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(7), offset: 1139.0, duration: 552.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(8), offset: 1691.0, duration: 157.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(9), offset: 1848.0, duration: 309.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(10), offset: 2157.0, duration: 1002.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(11), offset: 3159.0, duration: 1270.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(12), offset: 1267.0, duration: 378.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(13), offset: 1645.0, duration: 3248.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(14), offset: 3244.0, duration: 5413.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(15), offset: 1484.0, duration: 460.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(16), offset: 453.0, duration: 2028.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(17), offset: 2481.0, duration: 781.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(18), offset: 773.0, duration: 2413.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(19), offset: 3186.0, duration: 5518.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(20), offset: 637.0, duration: 723.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(21), offset: 1360.0, duration: 2281.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(22), offset: 0.0, duration: 3556.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(23), offset: 3556.0, duration: 2944.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(24), offset: 1.0, duration: 511.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(25), offset: 512.0, duration: 2885.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(26), offset: 0.0, duration: 806.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(27), offset: 806.0, duration: 3918.0, mediaType: .audioMPEG),
            TestOutcome(chapter: UInt(28), offset: 2160.0, duration: 751.0, mediaType: .audioMPEG)
        ]


    func testTocManifest() async throws {
        try await validate(manifest: "toc_manifest", against: tocManifestExpectedResults)
    }

    func testNonTockManifest() async throws {
        try await validate(manifest: "non_toc_manifest", against: nonTocManifestExpectedResults)
    }

    func testMartianManifest() async throws {
        try await validate(manifest: "the_martian_manifest", against: martianManifestExpectedResult)
    }

    func testSnowCrashManifest() async throws {
        try await validate(manifest: "snowcrash_manifest", against: snowCrashManifestExpectedResult)
    }
    
    func testChristmasCarolManifest() async throws {
        try await validate(manifest: "christmas_carol_manifest", against: christmasCarolManifestExpectedResults)
    }
    
    func testAnathemManifest() async throws {
        try await validate(manifest: "anathem_manifest", against: anathemManifestExpectedResults)
    }
    
    func testSystemOfTheWorldManifest() async throws {
        try await validate(manifest: "the_system_of_the_world_manifest", against: theSystemOfTheWorldManifestExpectedResults)
    }
    
    func testQuickSilverManifest() async throws {
        try await validate(manifest: "quicksilver_manifest", against: quicksilverManifestExpectedResults)
    }
    
    private func validate(manifest: String, against results: [TestOutcome]) async throws {
        // Assuming this function is part of a test class that has access to XCTest functions
        guard let url = Bundle(for: type(of: self)).url(forResource: manifest, withExtension: "json"),
              let jsonData = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let lcpAudiobook = LCPAudiobook(JSON: json, decryptor: nil) else {
            XCTFail("Failed to load manifest or create LCPAudiobook instance.")
            return
        }
        
        guard let spine = lcpAudiobook.spine as? [LCPSpineElement] else {
            XCTFail("Spine elements are not of type LCPSpineElement.")
            return
        }
        
        for (index, element) in spine.enumerated() where index < results.count {
            let expected = results[index]
            XCTAssertEqual(element.chapterNumber, expected.chapter, "Chapter number mismatch at index \(index).")
            XCTAssertEqual(element.offset, expected.offset, accuracy: 0.01, "Offset mismatch at index \(index).")
            XCTAssertEqual(element.duration, expected.duration, accuracy: 0.01, "Duration mismatch at index \(index).")
            XCTAssertEqual(element.mediaType, expected.mediaType, "Media type mismatch at index \(index).")
        }
    }


    private func fetchAudiobook(url: URL) async throws -> LCPAudiobook? {
        let jsonData = try Data(contentsOf: url, options: .mappedIfSafe)
        let string = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any]
        return LCPAudiobook(JSON: string, decryptor: nil)
    }
}
