import Metal
import PeekabooCore

/// Peekaboo renderer: Metal-based progressive image rendering.
public enum PeekabooRenderInfo {
    public static func defaultDevice() -> MTLDevice? { MTLCreateSystemDefaultDevice() }
}
