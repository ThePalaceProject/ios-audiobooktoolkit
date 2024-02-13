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
        TestOutcome(chapter: UInt(40), offset: 1472.0, duration: 216.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(41), offset: 6.0, duration: 1394.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(42), offset: 6.0, duration: 4.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(43), offset: 10.0, duration: 225.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(44), offset: 235.0, duration: 167.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(45), offset: 402.0, duration: 193.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(46), offset: 595.0, duration: 334.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(47), offset: 929.0, duration: 150.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(48), offset: 7.0, duration: 5.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(49), offset: 12.0, duration: 100.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(50), offset: 112.0, duration: 69.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(51), offset: 181.0, duration: 106.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(52), offset: 287.0, duration: 184.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(53), offset: 471.0, duration: 251.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(54), offset: 722.0, duration: 166.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(55), offset: 8.0, duration: 133.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(56), offset: 141.0, duration: 316.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(57), offset: 457.0, duration: 701.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(58), offset: 1158.0, duration: 313.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(59), offset: 1471.0, duration: 352.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(60), offset: 8.0, duration: 1273.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(61), offset: 8.0, duration: 37.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(62), offset: 45.0, duration: 183.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(63), offset: 228.0, duration: 160.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(64), offset: 388.0, duration: 197.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(65), offset: 585.0, duration: 166.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(66), offset: 751.0, duration: 210.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(67), offset: 961.0, duration: 265.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(68), offset: 9.0, duration: 3.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(69), offset: 12.0, duration: 36.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(70), offset: 48.0, duration: 72.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(71), offset: 120.0, duration: 190.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(72), offset: 310.0, duration: 160.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(73), offset: 470.0, duration: 133.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(74), offset: 603.0, duration: 203.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(75), offset: 806.0, duration: 103.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(76), offset: 909.0, duration: 73.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(77), offset: 982.0, duration: 84.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(78), offset: 1066.0, duration: 221.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(79), offset: 1287.0, duration: 109.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(80), offset: 1396.0, duration: 158.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(81), offset: 10.0, duration: 1835.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(82), offset: 10.0, duration: 2316.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(83), offset: 10.0, duration: 4.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(84), offset: 14.0, duration: 311.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(85), offset: 325.0, duration: 407.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(86), offset: 732.0, duration: 126.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(87), offset: 858.0, duration: 95.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(88), offset: 953.0, duration: 470.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(89), offset: 11.0, duration: 3.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(90), offset: 14.0, duration: 169.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(91), offset: 183.0, duration: 153.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(92), offset: 336.0, duration: 230.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(93), offset: 566.0, duration: 167.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(94), offset: 733.0, duration: 204.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(95), offset: 937.0, duration: 163.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(96), offset: 1100.0, duration: 195.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(97), offset: 1295.0, duration: 142.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(98), offset: 1437.0, duration: 215.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(99), offset: 12.0, duration: 1287.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(100), offset: 13.0, duration: 3.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(101), offset: 16.0, duration: 146.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(102), offset: 162.0, duration: 145.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(103), offset: 307.0, duration: 76.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(104), offset: 383.0, duration: 116.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(105), offset: 499.0, duration: 164.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(106), offset: 663.0, duration: 206.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(107), offset: 869.0, duration: 254.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(108), offset: 1123.0, duration: 224.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(109), offset: 1347.0, duration: 115.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(110), offset: 14.0, duration: 3.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(111), offset: 17.0, duration: 292.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(112), offset: 309.0, duration: 218.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(113), offset: 527.0, duration: 142.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(114), offset: 669.0, duration: 338.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(115), offset: 1007.0, duration: 292.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(116), offset: 1299.0, duration: 271.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(117), offset: 1570.0, duration: 203.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(118), offset: 15.0, duration: 3.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(119), offset: 18.0, duration: 256.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(120), offset: 274.0, duration: 245.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(121), offset: 519.0, duration: 154.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(122), offset: 673.0, duration: 192.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(123), offset: 865.0, duration: 118.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(124), offset: 983.0, duration: 88.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(125), offset: 1071.0, duration: 298.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(126), offset: 16.0, duration: 3.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(127), offset: 19.0, duration: 218.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(128), offset: 237.0, duration: 185.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(129), offset: 422.0, duration: 93.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(130), offset: 515.0, duration: 89.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(131), offset: 604.0, duration: 103.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(132), offset: 707.0, duration: 79.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(133), offset: 786.0, duration: 82.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(134), offset: 868.0, duration: 94.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(135), offset: 962.0, duration: 203.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(136), offset: 1165.0, duration: 300.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(137), offset: 16.0, duration: 106.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(138), offset: 122.0, duration: 163.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(139), offset: 285.0, duration: 160.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(140), offset: 445.0, duration: 228.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(141), offset: 673.0, duration: 126.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(142), offset: 799.0, duration: 354.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(143), offset: 1153.0, duration: 111.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(144), offset: 1264.0, duration: 34.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(145), offset: 1298.0, duration: 192.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(146), offset: 17.0, duration: 3.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(147), offset: 20.0, duration: 588.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(148), offset: 608.0, duration: 388.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(149), offset: 996.0, duration: 73.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(150), offset: 1069.0, duration: 242.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(151), offset: 1311.0, duration: 277.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(152), offset: 1588.0, duration: 199.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(153), offset: 17.0, duration: 2562.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(154), offset: 17.0, duration: 6.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(155), offset: 23.0, duration: 538.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(156), offset: 561.0, duration: 150.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(157), offset: 711.0, duration: 162.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(158), offset: 873.0, duration: 711.0, mediaType: .audioMPEG),
        TestOutcome(chapter: UInt(159), offset: 1584.0, duration: 30.0, mediaType: .audioMPEG)
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
        TestOutcome(chapter: UInt(5), offset: 2370.0, duration: 7.0, mediaType: .audioMPEG)
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
