import Foundation

// MARK: - User

public struct User: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: Int
    public var name: String
    public let email: String
    public let avatarUrl: String
    public var bio: String
    public let createdAt: Date

    public init(
        id: Int,
        name: String,
        email: String,
        avatarUrl: String,
        bio: String,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.avatarUrl = avatarUrl
        self.bio = bio
        self.createdAt = createdAt
    }
}

// MARK: - Post

public struct Post: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: Int
    public var title: String
    public var body: String
    public let authorId: Int
    public var likes: Int
    public let createdAt: Date

    public init(
        id: Int,
        title: String,
        body: String,
        authorId: Int,
        likes: Int,
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.authorId = authorId
        self.likes = likes
        self.createdAt = createdAt
    }
}

// MARK: - Comment

public struct Comment: Codable, Sendable, Identifiable, Equatable, Hashable {
    public let id: Int
    public let postId: Int
    public let authorId: Int
    public let body: String
    public let createdAt: Date

    public init(
        id: Int,
        postId: Int,
        authorId: Int,
        body: String,
        createdAt: Date
    ) {
        self.id = id
        self.postId = postId
        self.authorId = authorId
        self.body = body
        self.createdAt = createdAt
    }
}

// MARK: - Mutation Inputs

public struct CreateUserInput: Sendable {
    public let name: String
    public let email: String
    public let bio: String

    public init(name: String, email: String, bio: String = "") {
        self.name = name
        self.email = email
        self.bio = bio
    }
}

public struct UpdateUserInput: Sendable {
    public let id: Int
    public let name: String?
    public let bio: String?

    public init(id: Int, name: String? = nil, bio: String? = nil) {
        self.id = id
        self.name = name
        self.bio = bio
    }
}

public struct CreatePostInput: Sendable {
    public let title: String
    public let body: String
    public let authorId: Int

    public init(title: String, body: String, authorId: Int) {
        self.title = title
        self.body = body
        self.authorId = authorId
    }
}

public struct CreateCommentInput: Sendable {
    public let postId: Int
    public let authorId: Int
    public let body: String

    public init(postId: Int, authorId: Int, body: String) {
        self.postId = postId
        self.authorId = authorId
        self.body = body
    }
}
