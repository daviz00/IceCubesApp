import Foundation
import Models
import SwiftUI

public class Client: ObservableObject, Equatable {
  public static func == (lhs: Client, rhs: Client) -> Bool {
    lhs.isAuth == rhs.isAuth &&
      lhs.server == rhs.server &&
      lhs.oauthToken?.accessToken == rhs.oauthToken?.accessToken
  }

  public enum Version: String {
    case v1, v2
  }

  public enum OauthError: Error {
    case missingApp
    case invalidRedirectURL
  }

  public var server: String
  public let version: Version
  public private(set) var connections: Set<String>
  private let urlSession: URLSession
  private let decoder = JSONDecoder()

  /// Only used as a transitionary app while in the oauth flow.
  private var oauthApp: InstanceApp?

  private var oauthToken: OauthToken?

  public var isAuth: Bool {
    oauthToken != nil
  }

  public init(server: String, version: Version = .v1, oauthToken: OauthToken? = nil) {
    self.server = server
    self.version = version
    urlSession = URLSession.shared
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    self.oauthToken = oauthToken
    connections = Set([server])
  }

  public func addConnections(_ connections: [String]) {
    connections.forEach {
      self.connections.insert($0)
    }
  }

  public func hasConnection(with url: URL) -> Bool {
    guard let host = url.host else { return false }
    return connections.contains(host)
  }

  private func makeURL(scheme: String = "https", endpoint: Endpoint, forceVersion: Version? = nil) -> URL {
    var components = URLComponents()
    components.scheme = scheme
    components.host = server
    if type(of: endpoint) == Oauth.self {
      components.path += "/\(endpoint.path())"
    } else {
      components.path += "/api/\(forceVersion?.rawValue ?? version.rawValue)/\(endpoint.path())"
    }
    components.queryItems = endpoint.queryItems()
    return components.url!
  }

  private func makeURLRequest(url: URL, endpoint: Endpoint, httpMethod: String) -> URLRequest {
    var request = URLRequest(url: url)
    request.httpMethod = httpMethod
    if let oauthToken {
      request.setValue("Bearer \(oauthToken.accessToken)", forHTTPHeaderField: "Authorization")
    }
    if let json = endpoint.jsonValue {
      let encoder = JSONEncoder()
      encoder.keyEncodingStrategy = .convertToSnakeCase
      do {
        let jsonData = try encoder.encode(json)
        request.httpBody = jsonData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      } catch {
        print("Client Error encoding JSON: \(error.localizedDescription)")
      }
    }
    return request
  }

  private func makeGet(endpoint: Endpoint) -> URLRequest {
    let url = makeURL(endpoint: endpoint)
    return makeURLRequest(url: url, endpoint: endpoint, httpMethod: "GET")
  }

  public func get<Entity: Decodable>(endpoint: Endpoint, forceVersion: Version? = nil) async throws -> Entity {
    try await makeEntityRequest(endpoint: endpoint, method: "GET", forceVersion: forceVersion)
  }

  public func getWithLink<Entity: Decodable>(endpoint: Endpoint) async throws -> (Entity, LinkHandler?) {
    let (data, httpResponse) = try await urlSession.data(for: makeGet(endpoint: endpoint))
    var linkHandler: LinkHandler?
    if let response = httpResponse as? HTTPURLResponse,
       let link = response.allHeaderFields["Link"] as? String
    {
      linkHandler = .init(rawLink: link)
    }
    logResponseOnError(httpResponse: httpResponse, data: data)
    return (try decoder.decode(Entity.self, from: data), linkHandler)
  }

  public func post<Entity: Decodable>(endpoint: Endpoint) async throws -> Entity {
    try await makeEntityRequest(endpoint: endpoint, method: "POST")
  }

  public func post(endpoint: Endpoint) async throws -> HTTPURLResponse? {
    let url = makeURL(endpoint: endpoint)
    let request = makeURLRequest(url: url, endpoint: endpoint, httpMethod: "POST")
    let (_, httpResponse) = try await urlSession.data(for: request)
    return httpResponse as? HTTPURLResponse
  }

  public func patch(endpoint: Endpoint) async throws -> HTTPURLResponse? {
    let url = makeURL(endpoint: endpoint)
    let request = makeURLRequest(url: url, endpoint: endpoint, httpMethod: "PATCH")
    let (_, httpResponse) = try await urlSession.data(for: request)
    return httpResponse as? HTTPURLResponse
  }

  public func put<Entity: Decodable>(endpoint: Endpoint) async throws -> Entity {
    try await makeEntityRequest(endpoint: endpoint, method: "PUT")
  }

  public func delete(endpoint: Endpoint) async throws -> HTTPURLResponse? {
    let url = makeURL(endpoint: endpoint)
    let request = makeURLRequest(url: url, endpoint: endpoint, httpMethod: "DELETE")
    let (_, httpResponse) = try await urlSession.data(for: request)
    return httpResponse as? HTTPURLResponse
  }

  private func makeEntityRequest<Entity: Decodable>(endpoint: Endpoint,
                                                    method: String,
                                                    forceVersion: Version? = nil) async throws -> Entity
  {
    let url = makeURL(endpoint: endpoint, forceVersion: forceVersion)
    let request = makeURLRequest(url: url, endpoint: endpoint, httpMethod: method)
    let (data, httpResponse) = try await urlSession.data(for: request)
    logResponseOnError(httpResponse: httpResponse, data: data)
    do {
      return try decoder.decode(Entity.self, from: data)
    } catch {
      if let serverError = try? decoder.decode(ServerError.self, from: data) {
        throw serverError
      }
      throw error
    }
  }

  public func oauthURL() async throws -> URL {
    let app: InstanceApp = try await post(endpoint: Apps.registerApp)
    oauthApp = app
    return makeURL(endpoint: Oauth.authorize(clientId: app.clientId))
  }

  public func continueOauthFlow(url: URL) async throws -> OauthToken {
    guard let app = oauthApp else {
      throw OauthError.missingApp
    }
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let code = components.queryItems?.first(where: { $0.name == "code" })?.value
    else {
      throw OauthError.invalidRedirectURL
    }
    let token: OauthToken = try await post(endpoint: Oauth.token(code: code,
                                                                 clientId: app.clientId,
                                                                 clientSecret: app.clientSecret))
    oauthToken = token
    return token
  }

  public func makeWebSocketTask(endpoint: Endpoint) -> URLSessionWebSocketTask {
    let url = makeURL(scheme: "wss", endpoint: endpoint)
    let request = makeURLRequest(url: url, endpoint: endpoint, httpMethod: "GET")
    return urlSession.webSocketTask(with: request)
  }

  public func mediaUpload<Entity: Decodable>(endpoint: Endpoint,
                                             version: Version,
                                             method: String,
                                             mimeType: String,
                                             filename: String,
                                             data: Data) async throws -> Entity
  {
    let url = makeURL(endpoint: endpoint, forceVersion: version)
    var request = makeURLRequest(url: url, endpoint: endpoint, httpMethod: method)
    let boundary = UUID().uuidString
    request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
    let httpBody = NSMutableData()
    httpBody.append("--\(boundary)\r\n".data(using: .utf8)!)
    httpBody.append("Content-Disposition: form-data; name=\"\(filename)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
    httpBody.append("Content-Type: \(mimeType)\r\n".data(using: .utf8)!)
    httpBody.append("\r\n".data(using: .utf8)!)
    httpBody.append(data)
    httpBody.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
    request.httpBody = httpBody as Data
    let (data, httpResponse) = try await urlSession.data(for: request)
    logResponseOnError(httpResponse: httpResponse, data: data)
    return try decoder.decode(Entity.self, from: data)
  }

  private func logResponseOnError(httpResponse: URLResponse, data: Data) {
    if let httpResponse = httpResponse as? HTTPURLResponse, httpResponse.statusCode > 299 {
      print(httpResponse)
      print(String(data: data, encoding: .utf8) ?? "")
    }
  }
}
