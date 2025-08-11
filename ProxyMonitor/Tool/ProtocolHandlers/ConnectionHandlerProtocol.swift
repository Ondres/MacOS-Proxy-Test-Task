import Foundation
import Network

protocol ConnectionHandlerProtocol: AnyObject {
    func canHandle(firstBytes: Data) -> Bool
    func handle(client: NWConnection, firstBytes: Data)
}
