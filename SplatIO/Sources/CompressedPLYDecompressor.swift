import Foundation
import PLYIO
import simd

/// Decompressor for compressed PlayCanvas PLY files
/// 
/// Compressed PLY files use quantized values (uint8/uint16) instead of float32.
/// This decompressor converts quantized values back to their original float32 ranges.
internal struct CompressedPLYDecompressor {
    /// Quantization ranges for different property types
    struct QuantizationRanges {
        // Position quantization (typically in world space bounds)
        let positionMin: SIMD3<Float>
        let positionMax: SIMD3<Float>
        
        // Scale quantization (log space, typically -20 to 20)
        let scaleMin: Float
        let scaleMax: Float
        
        // Rotation quantization (quaternion components, -1 to 1)
        let rotationMin: Float
        let rotationMax: Float
        
        // Opacity quantization (logit space, typically -10 to 10)
        let opacityMin: Float
        let opacityMax: Float
        
        // Color quantization (SH coefficients, typically -1 to 1)
        let colorMin: Float
        let colorMax: Float
        
        /// Custom initializer with all parameters
        init(positionMin: SIMD3<Float>,
             positionMax: SIMD3<Float>,
             scaleMin: Float = -20.0,
             scaleMax: Float = 20.0,
             rotationMin: Float = -1.0,
             rotationMax: Float = 1.0,
             opacityMin: Float = -10.0,
             opacityMax: Float = 10.0,
             colorMin: Float = -1.0,
             colorMax: Float = 1.0) {
            self.positionMin = positionMin
            self.positionMax = positionMax
            self.scaleMin = scaleMin
            self.scaleMax = scaleMax
            self.rotationMin = rotationMin
            self.rotationMax = rotationMax
            self.opacityMin = opacityMin
            self.opacityMax = opacityMax
            self.colorMin = colorMin
            self.colorMax = colorMax
        }
        
        static let `default` = QuantizationRanges(
            positionMin: SIMD3<Float>(-100.0, -100.0, -100.0),
            positionMax: SIMD3<Float>(100.0, 100.0, 100.0)
        )
    }
    
    /// Dequantize a uint8 value to float32 in the given range
    /// Optimized with precomputed constants for better performance
    @inlinable
    static func dequantizeUInt8(_ value: UInt8, min: Float, max: Float) -> Float {
        let normalized = Float(value) * (1.0 / 255.0) // Use multiplication instead of division
        return min + normalized * (max - min)
    }
    
    /// Dequantize a uint16 value to float32 in the given range
    /// Optimized with precomputed constants for better performance
    @inlinable
    static func dequantizeUInt16(_ value: UInt16, min: Float, max: Float) -> Float {
        let normalized = Float(value) * (1.0 / 65535.0) // Use multiplication instead of division
        return min + normalized * (max - min)
    }
    
    /// Dequantize a uint8 value to float32 for position (3D)
    static func dequantizePositionUInt8(_ value: UInt8, component: Int, ranges: QuantizationRanges) -> Float {
        let min = component == 0 ? ranges.positionMin.x : (component == 1 ? ranges.positionMin.y : ranges.positionMin.z)
        let max = component == 0 ? ranges.positionMax.x : (component == 1 ? ranges.positionMax.y : ranges.positionMax.z)
        return dequantizeUInt8(value, min: min, max: max)
    }
    
    /// Dequantize a uint16 value to float32 for position (3D)
    static func dequantizePositionUInt16(_ value: UInt16, component: Int, ranges: QuantizationRanges) -> Float {
        let min = component == 0 ? ranges.positionMin.x : (component == 1 ? ranges.positionMin.y : ranges.positionMin.z)
        let max = component == 0 ? ranges.positionMax.x : (component == 1 ? ranges.positionMax.y : ranges.positionMax.z)
        return dequantizeUInt16(value, min: min, max: max)
    }
    
    /// Convert a quantized PLY element property to float32
    /// - Parameters:
    ///   - property: The quantized property (uint8 or uint16)
    ///   - propertyName: Name of the property to determine quantization range
    ///   - ranges: Quantization ranges to use
    /// - Returns: Dequantized float32 value
    static func dequantizeProperty(_ property: PLYElement.Property, 
                                   propertyName: String,
                                   ranges: QuantizationRanges = .default) -> Float? {
        let lowerName = propertyName.lowercased()
        
        // Determine quantization range based on property name
        let (min, max): (Float, Float)
        if lowerName.contains("x") || lowerName.contains("y") || lowerName.contains("z") {
            // Position component - use position ranges
            let component = lowerName.contains("x") ? 0 : (lowerName.contains("y") ? 1 : 2)
            if case .uint8(let val) = property {
                return dequantizePositionUInt8(val, component: component, ranges: ranges)
            } else if case .uint16(let val) = property {
                return dequantizePositionUInt16(val, component: component, ranges: ranges)
            }
            return nil
        } else if lowerName.contains("scale") {
            (min, max) = (ranges.scaleMin, ranges.scaleMax)
        } else if lowerName.contains("opacity") {
            (min, max) = (ranges.opacityMin, ranges.opacityMax)
        } else if lowerName.contains("rot") || lowerName.contains("rotation") {
            (min, max) = (ranges.rotationMin, ranges.rotationMax)
        } else if lowerName.contains("f_dc") || lowerName.contains("f_rest") || lowerName.contains("sh") {
            (min, max) = (ranges.colorMin, ranges.colorMax)
        } else {
            // Default range for unknown properties
            (min, max) = (-1.0, 1.0)
        }
        
        // Dequantize based on type
        switch property {
        case .uint8(let value):
            return dequantizeUInt8(value, min: min, max: max)
        case .uint16(let value):
            return dequantizeUInt16(value, min: min, max: max)
        case .float32(let value):
            // Already a float, return as-is
            return value
        case .float64(let value):
            return Float(value)
        default:
            return nil
        }
    }
    
    /// Extract quantization ranges from PLY header comments
    /// Compressed PLY files may include quantization bounds in comments
    static func extractQuantizationRanges(from header: PLYHeader) -> QuantizationRanges {
        // Default ranges - in a real implementation, these would be extracted from header comments
        // For now, we use reasonable defaults that work for most Gaussian splatting data
        return .default
    }
}

