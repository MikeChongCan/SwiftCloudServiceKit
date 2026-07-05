import Foundation
import CloudServiceKit

@main
struct CLI {
    static func main() async {
        print("CloudServiceKit CLI Example running...")
        
        let endpoint = URL(string: "http://localhost:8080")!
        let credential = URLCredential(user: "user", password: "password", persistence: .none)
        let provider = WebDAVServiceProvider(endpoint: endpoint, credential: credential)
        
        print("Configured WebDAV provider: \(provider.name) at \(provider.endpoint)")
    }
}
