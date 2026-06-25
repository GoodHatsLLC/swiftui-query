import Foundation

/// A mock HTTP server that simulates network conditions including latency, errors, and failures.
/// Uses an actor for thread-safe state management.
public actor MockServer {

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Base latency range in milliseconds
        public var latencyRange: ClosedRange<UInt64>
        /// Probability of a request failing (0.0 - 1.0)
        public var failureRate: Double
        /// Whether the server is "down" (all requests fail)
        public var isDown: Bool
        /// Simulated network timeout in seconds
        public var timeoutDuration: TimeInterval

        public init(
            latencyRange: ClosedRange<UInt64> = 200...800,
            failureRate: Double = 0.0,
            isDown: Bool = false,
            timeoutDuration: TimeInterval = 30
        ) {
            self.latencyRange = latencyRange
            self.failureRate = failureRate
            self.isDown = isDown
            self.timeoutDuration = timeoutDuration
        }

        /// Fast responses, no failures
        public static let fast = Configuration(latencyRange: 50...100, failureRate: 0.0)

        /// Slow responses simulating poor network
        public static let slow = Configuration(latencyRange: 1500...3000, failureRate: 0.0)

        /// Flaky network with occasional failures
        public static let flaky = Configuration(latencyRange: 200...800, failureRate: 0.3)

        /// Very unreliable network
        public static let unreliable = Configuration(latencyRange: 500...2000, failureRate: 0.5)
    }

    // MARK: - Errors

    public enum ServerError: LocalizedError, Sendable {
        case serverDown
        case internalError(code: Int)
        case notFound(resource: String)
        case timeout
        case networkError
        case rateLimited
        case unauthorized

        public var errorDescription: String? {
            switch self {
            case .serverDown:
                return "Server is currently unavailable"
            case .internalError(let code):
                return "Internal server error (HTTP \(code))"
            case .notFound(let resource):
                return "Resource not found: \(resource)"
            case .timeout:
                return "Request timed out"
            case .networkError:
                return "Network connection failed"
            case .rateLimited:
                return "Too many requests. Please try again later."
            case .unauthorized:
                return "Authentication required"
            }
        }
    }

    // MARK: - State

    public var configuration: Configuration
    private var users: [Int: User] = [:]
    private var posts: [Int: Post] = [:]
    private var comments: [Int: Comment] = [:]
    private var nextUserId = 1
    private var nextPostId = 1
    private var nextCommentId = 1
    private var requestCount = 0

    // MARK: - Initialization

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        // Seed data inline since we can't call async methods from init
        seedInitialData()
    }

    private nonisolated func seedInitialData() {
        // Data is seeded lazily on first access via Task
        Task { await self.seedDataIfNeeded() }
    }

    private var isSeeded = false

    private func seedDataIfNeeded() {
        guard !isSeeded else { return }
        isSeeded = true
        seedData()
    }

    private func seedData() {
        // Seed users
        let userNames = ["Alice", "Bob", "Charlie", "Diana", "Eve", "Frank"]
        for name in userNames {
            let user = User(
                id: nextUserId,
                name: name,
                email: "\(name.lowercased())@example.com",
                avatarUrl: "https://api.dicebear.com/7.x/avataaars/svg?seed=\(name)",
                bio: "Hello, I'm \(name)!",
                createdAt: Date().addingTimeInterval(-Double.random(in: 86400...864000))
            )
            users[nextUserId] = user
            nextUserId += 1
        }

        // Seed posts
        let postTitles = [
            "Getting Started with SwiftUI",
            "Understanding Async/Await",
            "Building Better Apps",
            "The Art of Caching",
            "React Query for Swift",
            "State Management Tips",
            "Performance Optimization",
            "Clean Architecture"
        ]

        for (index, title) in postTitles.enumerated() {
            let authorId = (index % userNames.count) + 1
            let post = Post(
                id: nextPostId,
                title: title,
                body: "This is the content of '\(title)'. Lorem ipsum dolor sit amet, consectetur adipiscing elit. Sed do eiusmod tempor incididunt ut labore et dolore magna aliqua.",
                authorId: authorId,
                likes: Int.random(in: 0...100),
                createdAt: Date().addingTimeInterval(-Double.random(in: 3600...604800))
            )
            posts[nextPostId] = post
            nextPostId += 1
        }

        // Seed comments
        for postId in 1..<nextPostId {
            let commentCount = Int.random(in: 1...5)
            for _ in 0..<commentCount {
                let authorId = Int.random(in: 1..<nextUserId)
                let comment = Comment(
                    id: nextCommentId,
                    postId: postId,
                    authorId: authorId,
                    body: ["Great post!", "Thanks for sharing!", "Very helpful!", "I learned something new!", "Could you elaborate more?"].randomElement()!,
                    createdAt: Date().addingTimeInterval(-Double.random(in: 0...3600))
                )
                comments[nextCommentId] = comment
                nextCommentId += 1
            }
        }
    }

    // MARK: - Network Simulation

    private func simulateLatency() async throws {
        let latency = UInt64.random(in: configuration.latencyRange)
        try await Task.sleep(nanoseconds: latency * 1_000_000)
    }

    private func shouldFail() -> Bool {
        return Double.random(in: 0...1) < configuration.failureRate
    }

    private func checkServerStatus() throws {
        if configuration.isDown {
            throw ServerError.serverDown
        }
    }

    private func simulateRequest() async throws {
        requestCount += 1
        try checkServerStatus()
        try await simulateLatency()

        if shouldFail() {
            let errors: [ServerError] = [
                .internalError(code: 500),
                .internalError(code: 502),
                .internalError(code: 503),
                .timeout,
                .networkError
            ]
            throw errors.randomElement()!
        }
    }

    // MARK: - Configuration Methods

    public func updateConfiguration(_ config: Configuration) {
        self.configuration = config
    }

    public func setServerDown(_ down: Bool) {
        configuration.isDown = down
    }

    public func setFailureRate(_ rate: Double) {
        configuration.failureRate = max(0, min(1, rate))
    }

    public func setLatency(_ range: ClosedRange<UInt64>) {
        configuration.latencyRange = range
    }

    public func getRequestCount() -> Int {
        return requestCount
    }

    public func resetRequestCount() {
        requestCount = 0
    }

    // MARK: - User Endpoints

    public func getUsers() async throws -> [User] {
        try await simulateRequest()
        return Array(users.values).sorted { $0.id < $1.id }
    }

    public func getUser(id: Int) async throws -> User {
        try await simulateRequest()
        guard let user = users[id] else {
            throw ServerError.notFound(resource: "User \(id)")
        }
        return user
    }

    public func createUser(name: String, email: String, bio: String = "") async throws -> User {
        try await simulateRequest()
        let user = User(
            id: nextUserId,
            name: name,
            email: email,
            avatarUrl: "https://api.dicebear.com/7.x/avataaars/svg?seed=\(name)",
            bio: bio,
            createdAt: Date()
        )
        users[nextUserId] = user
        nextUserId += 1
        return user
    }

    public func updateUser(id: Int, name: String? = nil, bio: String? = nil) async throws -> User {
        try await simulateRequest()
        guard var user = users[id] else {
            throw ServerError.notFound(resource: "User \(id)")
        }
        if let name = name { user.name = name }
        if let bio = bio { user.bio = bio }
        users[id] = user
        return user
    }

    public func deleteUser(id: Int) async throws {
        try await simulateRequest()
        guard users[id] != nil else {
            throw ServerError.notFound(resource: "User \(id)")
        }
        users.removeValue(forKey: id)
        // Also remove user's posts and comments
        posts = posts.filter { $0.value.authorId != id }
        comments = comments.filter { $0.value.authorId != id }
    }

    // MARK: - Post Endpoints

    public func getPosts() async throws -> [Post] {
        try await simulateRequest()
        return Array(posts.values).sorted { $0.createdAt > $1.createdAt }
    }

    public func getPost(id: Int) async throws -> Post {
        try await simulateRequest()
        guard let post = posts[id] else {
            throw ServerError.notFound(resource: "Post \(id)")
        }
        return post
    }

    public func getUserPosts(userId: Int) async throws -> [Post] {
        try await simulateRequest()
        guard users[userId] != nil else {
            throw ServerError.notFound(resource: "User \(userId)")
        }
        return Array(posts.values)
            .filter { $0.authorId == userId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func createPost(title: String, body: String, authorId: Int) async throws -> Post {
        try await simulateRequest()
        guard users[authorId] != nil else {
            throw ServerError.notFound(resource: "User \(authorId)")
        }
        let post = Post(
            id: nextPostId,
            title: title,
            body: body,
            authorId: authorId,
            likes: 0,
            createdAt: Date()
        )
        posts[nextPostId] = post
        nextPostId += 1
        return post
    }

    public func updatePost(id: Int, title: String? = nil, body: String? = nil) async throws -> Post {
        try await simulateRequest()
        guard var post = posts[id] else {
            throw ServerError.notFound(resource: "Post \(id)")
        }
        if let title = title { post.title = title }
        if let body = body { post.body = body }
        posts[id] = post
        return post
    }

    public func deletePost(id: Int) async throws {
        try await simulateRequest()
        guard posts[id] != nil else {
            throw ServerError.notFound(resource: "Post \(id)")
        }
        posts.removeValue(forKey: id)
        // Also remove post's comments
        comments = comments.filter { $0.value.postId != id }
    }

    public func likePost(id: Int) async throws -> Post {
        try await simulateRequest()
        guard var post = posts[id] else {
            throw ServerError.notFound(resource: "Post \(id)")
        }
        post.likes += 1
        posts[id] = post
        return post
    }

    // MARK: - Comment Endpoints

    public func getPostComments(postId: Int) async throws -> [Comment] {
        try await simulateRequest()
        guard posts[postId] != nil else {
            throw ServerError.notFound(resource: "Post \(postId)")
        }
        return Array(comments.values)
            .filter { $0.postId == postId }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func createComment(postId: Int, authorId: Int, body: String) async throws -> Comment {
        try await simulateRequest()
        guard posts[postId] != nil else {
            throw ServerError.notFound(resource: "Post \(postId)")
        }
        guard users[authorId] != nil else {
            throw ServerError.notFound(resource: "User \(authorId)")
        }
        let comment = Comment(
            id: nextCommentId,
            postId: postId,
            authorId: authorId,
            body: body,
            createdAt: Date()
        )
        comments[nextCommentId] = comment
        nextCommentId += 1
        return comment
    }

    public func deleteComment(id: Int) async throws {
        try await simulateRequest()
        guard comments[id] != nil else {
            throw ServerError.notFound(resource: "Comment \(id)")
        }
        comments.removeValue(forKey: id)
    }
}
