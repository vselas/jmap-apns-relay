import AsyncHTTPClient
import Foundation
import AWSLambdaEvents
import HummingbirdLambda
import RelayAWS
import RelayAppStore
import RelayLambdaSupport
import RelayCore

/// The relay as an AWS Lambda behind a Function URL.
///
/// Same router, same protocol, same tests as the Docker relay; only storage
/// (DynamoDB instead of a JSON file), secrets (Parameter Store instead of a
/// mounted volume) and TLS (the Function URL's instead of our own) differ.
/// Everything below runs once per cold start and is reused by every request
/// the instance serves afterwards — the APNs JWT cache included.
// Not the stock `FunctionURLRequest`: that one cannot decode a request
// without a User-Agent, which is every request Stalwart sends.
typealias LambdaContext = BasicLambdaRequestContext<TolerantFunctionURLRequest>

let httpClient = HTTPClient(eventLoopGroupProvider: .singleton)
let processEnvironment = ProcessInfo.processInfo.environment
let aws = try AWSEnvironment(environment: processEnvironment)
let transport = SignedAWSTransport(environment: aws, httpClient: httpClient)
let environment = try await ParameterStore.resolve(environment: processEnvironment, transport: transport)

// Same fail-closed rules as the container: production refuses to start
// without the bearer token and complete APNs credentials.
let runtime = try RuntimeConfiguration(environment: environment)
guard let table = environment["DYNAMODB_TABLE"], !table.isEmpty else {
    relayLog("[push] DYNAMODB_TABLE is not set")
    exit(1)
}
let store = DynamoDBRelayStore(transport: transport, table: table)
let sender = try await makeSender(runtime: runtime, httpClient: httpClient, ownsClient: false)

// Selling push: APPSTORE_PRODUCT_IDS turns it on. A registration then needs
// Apple's signature on an active subscription *in addition to* the shared
// token: the token keeps scripted clients out, the subscription is what pays.
let entitlements = try AppStoreEntitlementVerifier.fromEnvironment(environment).map {
    EntitlementPolicy(
        verifier: $0,
        maxDevicesPerEntitlement: environment["APPSTORE_MAX_DEVICES"].flatMap(Int.init) ?? 10
    )
}
if entitlements != nil {
    relayLog("[push] App Store entitlements required for APNs delivery")
} else if runtime.authToken == nil {
    relayLog("[push] WARNING: RELAY_AUTH_TOKEN is not set — /v1/register accepts any device id.")
}

let router = buildRouter(
    context: LambdaContext.self, store: store, sender: sender,
    authToken: runtime.authToken, entitlements: entitlements
)
relayLog("[push] Lambda relay ready (mode \(runtime.mode.rawValue), table \(table))")
let lambda = LambdaFunction(
    router: router, event: TolerantFunctionURLRequest.self, output: FunctionURLResponse.self
)
try await lambda.runService()
