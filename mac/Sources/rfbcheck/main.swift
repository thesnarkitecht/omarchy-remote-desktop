// Self-check tool: connect, grab one full frame, write it as a binary PPM.
// usage: rfbcheck <host> <port> <out.ppm>
import Foundation
import RFB

let args = CommandLine.arguments
guard args.count == 4, let port = Int(args[2]) else {
    FileHandle.standardError.write("usage: rfbcheck <host> <port> <out.ppm>\n".data(using: .utf8)!)
    exit(2)
}
do {
    let conn = try RFBConnection(host: args[1], port: port)
    let done = DispatchSemaphore(value: 0)
    conn.onFrame = { done.signal() }
    conn.onClose = { print("closed: \($0)"); exit(1) }
    conn.start()
    done.wait()
    conn.lock.lock()
    var ppm = Data("P6\n\(conn.width) \(conn.height)\n255\n".utf8)
    ppm.append(contentsOf: conn.pixels.flatMap { [UInt8(($0 >> 16) & 0xFF), UInt8(($0 >> 8) & 0xFF), UInt8($0 & 0xFF)] })
    conn.lock.unlock()
    try ppm.write(to: URL(fileURLWithPath: args[3]))
    print("\(conn.name): \(conn.width)x\(conn.height) -> \(args[3])")
    conn.disconnect()
} catch {
    print("error: \(error)")
    exit(1)
}
