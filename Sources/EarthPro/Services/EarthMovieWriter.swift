import AVFoundation
import CoreGraphics

actor EarthMovieWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let width: Int, height: Int
    private var frames=0
    private var lastTime = -1.0
    init(url: URL, width: Int, height: Int) throws {
        self.width=width; self.height=height
        // Never silently overwrite an existing recording.
        guard !FileManager.default.fileExists(atPath:url.path) else { throw KMLError.invalid("A file already exists at this path. Choose a new recording filename.") }
        writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
        input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:width,AVVideoHeightKey:height])
        input.expectsMediaDataInRealTime=true
        adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32ARGB,kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,kCVPixelBufferCGImageCompatibilityKey as String:true,kCVPixelBufferCGBitmapContextCompatibilityKey as String:true])
        guard writer.canAdd(input) else { throw KMLError.invalid("Video encoding is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? KMLError.invalid("Video encoder could not start.") }
        writer.startSession(atSourceTime:.zero)
    }
    func append(_ image: CGImage, seconds: Double) throws {
        guard writer.status == .writing else { throw writer.error ?? KMLError.invalid("Video encoder stopped.") }
        guard input.isReadyForMoreMediaData, seconds > lastTime else { return }
        var buffer: CVPixelBuffer?
        guard let pool=adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil,pool,&buffer)==kCVReturnSuccess, let buffer else { throw KMLError.invalid("Cannot allocate a video frame.") }
        CVPixelBufferLockBaseAddress(buffer,[]); defer { CVPixelBufferUnlockBaseAddress(buffer,[]) }
        guard let context=CGContext(data:CVPixelBufferGetBaseAddress(buffer),width:width,height:height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw KMLError.invalid("Cannot create a video frame.") }
        context.setFillColor(CGColor(gray:0,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
        let scale=min(Double(width)/Double(image.width),Double(height)/Double(image.height))
        let w=Double(image.width)*scale,h=Double(image.height)*scale
        context.draw(image,in:CGRect(x:(Double(width)-w)/2,y:(Double(height)-h)/2,width:w,height:h))
        guard adaptor.append(buffer,withPresentationTime:CMTime(seconds:seconds,preferredTimescale:600)) else { throw writer.error ?? KMLError.invalid("Cannot encode video frame.") }
        frames+=1; lastTime=seconds
    }
    func finish() async throws {
        guard frames>0 else { writer.cancelWriting(); throw KMLError.invalid("No video frames were captured. Let the map load before recording.") }
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? KMLError.invalid("Video could not be saved.") }
    }
}
