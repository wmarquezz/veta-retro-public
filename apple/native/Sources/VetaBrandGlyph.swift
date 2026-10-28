import CoreGraphics

/// Original orange sketch: deliberately uneven pen strokes, no lettering.
/// Shared vector geometry for the app header and home-screen icon.
enum VetaBrandGlyph {
    private static func stroke(_ points:[(CGFloat,CGFloat)],width:CGFloat)->CGPath {
        let p=CGMutablePath();p.move(to:CGPoint(x:points[0].0,y:points[0].1))
        for (x,y) in points.dropFirst() {p.addLine(to:CGPoint(x:x,y:y))}
        return p.copy(strokingWithWidth:width,lineCap:.round,lineJoin:.round,miterLimit:2)
    }
    static var layers:[(CGPath,UInt32)] {
        let outline=CGMutablePath()
        outline.move(to:CGPoint(x:11,y:39))
        outline.addCurve(to:CGPoint(x:29,y:28),control1:CGPoint(x:12,y:24),control2:CGPoint(x:21,y:24))
        outline.addLine(to:CGPoint(x:37,y:32));outline.addLine(to:CGPoint(x:62,y:30))
        outline.addCurve(to:CGPoint(x:85,y:33),control1:CGPoint(x:75,y:22),control2:CGPoint(x:81,y:24))
        outline.addCurve(to:CGPoint(x:95,y:73),control1:CGPoint(x:91,y:45),control2:CGPoint(x:92,y:59))
        outline.addCurve(to:CGPoint(x:83,y:79),control1:CGPoint(x:97,y:82),control2:CGPoint(x:90,y:85))
        outline.addLine(to:CGPoint(x:68,y:64));outline.addLine(to:CGPoint(x:34,y:66))
        outline.addCurve(to:CGPoint(x:13,y:81),control1:CGPoint(x:20,y:85),control2:CGPoint(x:18,y:84))
        outline.addCurve(to:CGPoint(x:11,y:39),control1:CGPoint(x:3,y:78),control2:CGPoint(x:9,y:47))
        let cross=stroke([(23,38),(23,45),(16,46),(16,51),(24,51),(24,58),(29,57),(28,50),(35,49),(34,44),(28,45),(28,38),(23,38)],width:2.8)
        let first=stroke([(69,46),(67,49),(70,53),(74,51),(74,47),(71,45),(69,46)],width:2.5)
        let second=stroke([(79,36),(77,40),(80,44),(84,42),(84,38),(81,36),(79,36)],width:2.5)
        var result:[(CGPath,UInt32)]=[
            (outline.copy(strokingWithWidth:3.8,lineCap:.round,lineJoin:.round,miterLimit:2),0xff853b),
            (stroke([(7,61),(6,77),(12,85),(19,83),(33,69),(62,67)],width:1.5),0xffb16a),
            (stroke([(39,29),(60,27),(72,23),(80,24),(87,32),(92,48),(98,75)],width:1.4),0xffb16a),
            (cross,0xff853b),(first,0xff853b),(second,0xff853b),
            (stroke([(45,53),(49,52)],width:2.6),0xff853b),
            (stroke([(54,51),(58,50)],width:2.8),0xff853b)
        ]
        // Short, unequal hatching marks give the grips their hand-drawn texture.
        for points:[(CGFloat,CGFloat)] in [
            [(12,65),(18,59)],[(11,72),(20,62)],[(13,77),(24,65)],[(18,77),(27,68)],
            [(78,64),(85,59)],[(81,69),(87,64)],[(85,73),(89,69)],[(87,77),(92,73)],
            [(16,31),(22,29)],[(15,34),(24,31)]
        ] {result.append((stroke(points,width:1.5),0xff853b))}
        return result
    }
}
