import Foundation
import CoreGraphics

struct CaptureGeometry {
    // Unit coordinates are top-left relative to the selected display, independent of
    // global monitor placement and Retina scale.
    static func normalized(_ rect: CGRect, in size: CGSize) throws -> CGRect {
        guard size.width > 0, size.height > 0 else { throw ForgeError.message("Display size is unavailable.") }
        let clipped = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        guard !clipped.isNull, clipped.width >= 16, clipped.height >= 16 else { throw ForgeError.message("Drag a region at least 16 × 16 points.") }
        return CGRect(x: clipped.minX/size.width, y: clipped.minY/size.height, width: clipped.width/size.width, height: clipped.height/size.height)
    }
    static func sourceRect(_ normalized: CGRect?, logicalSize: CGSize) throws -> CGRect {
        let unit = normalized ?? CGRect(x: 0,y: 0,width: 1,height: 1)
        guard unit.minX.isFinite, unit.minY.isFinite, unit.width.isFinite, unit.height.isFinite,
              unit.minX >= 0, unit.minY >= 0, unit.maxX <= 1.000001, unit.maxY <= 1.000001, unit.width > 0, unit.height > 0 else { throw ForgeError.message("Select the recording region again.") }
        return CGRect(x: unit.minX*logicalSize.width,y: unit.minY*logicalSize.height,width: unit.width*logicalSize.width,height: unit.height*logicalSize.height)
    }
    static func outputSize(source: CGSize, scale: CGFloat, maximumDimension: Int) -> CGSize {
        let native = CGSize(width: source.width*scale,height: source.height*scale)
        let ratio = maximumDimension > 0 ? min(1,CGFloat(maximumDimension)/max(native.width,native.height)) : 1
        return CGSize(width: max(2,floor(native.width*ratio/2)*2),height: max(2,floor(native.height*ratio/2)*2))
    }
}
