import CompositorServices
import SwiftUI

struct SHARConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities, configuration: inout LayerRenderer.Configuration) {
        // One 2-slice texture per frame, matching the engine's arraySize-2 OpenXR swapchain.
        configuration.layout = capabilities.supportedLayouts(options: []).contains(.layered) ? .layered : .dedicated
        // The engine doesn't render with rasterization rate maps, so foveated drawables would warp.
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
        // PCVR's colour contract: sRGB storage, rendered through a UNORM view of it. That view
        // differs only in sRGB, which the default usage (renderTarget | shaderRead) allows. Keep
        // the default: the first tests on the headset ran with it, while adding .pixelFormatView was
        // only ever tested in the Simulator.
        NSLog("%@", "[SHARVR] layer config: layout \(configuration.layout), colour \(configuration.colorFormat.rawValue) "
              + "usage \(configuration.colorUsage.rawValue), depth \(configuration.depthFormat.rawValue) "
              + "usage \(configuration.depthUsage.rawValue); supported colour \(capabilities.supportedColorFormats(options: []).map(\.rawValue)), "
              + "depth \(capabilities.supportedDepthFormats.map(\.rawValue)); progressive: layouts "
              + "\(capabilities.supportedLayouts(options: .progressiveImmersionEnabled)), colour "
              + "\(capabilities.supportedColorFormats(options: .progressiveImmersionEnabled).map(\.rawValue))")
    }
}
