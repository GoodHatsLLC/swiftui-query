import SwiftUIQuery

// MARK: - User Queries

/// Fetches all users
struct UsersQuery: QueryKey {
    typealias Response = [User]

    var identity: QueryIdentity { QueryIdentity("users", "all") }
    var invalidationTags: Set<QueryTag> { [.users] }
}

/// Fetches a single user by ID
struct UserQuery: QueryKey {
    typealias Response = User
    let userId: Int

    var identity: QueryIdentity { QueryIdentity("users", userId) }
    var invalidationTags: Set<QueryTag> { [.users] }
}

// MARK: - Post Queries

/// Fetches all posts
struct PostsQuery: QueryKey {
    typealias Response = [Post]

    var identity: QueryIdentity { QueryIdentity("posts", "all") }
    var invalidationTags: Set<QueryTag> { [.posts] }
}

/// Fetches a single post by ID
struct PostQuery: QueryKey {
    typealias Response = Post
    let postId: Int

    var identity: QueryIdentity { QueryIdentity("posts", postId) }
    var invalidationTags: Set<QueryTag> { [.posts] }
}

/// Fetches posts by a specific user
struct UserPostsQuery: QueryKey {
    typealias Response = [Post]
    let userId: Int

    var identity: QueryIdentity { QueryIdentity("users", userId, "posts") }
    var invalidationTags: Set<QueryTag> { [.posts] }
}

// MARK: - Comment Queries

/// Fetches comments for a specific post
struct PostCommentsQuery: QueryKey {
    typealias Response = [Comment]
    let postId: Int

    var identity: QueryIdentity { QueryIdentity("posts", postId, "comments") }
    var invalidationTags: Set<QueryTag> { [.comments] }
}
