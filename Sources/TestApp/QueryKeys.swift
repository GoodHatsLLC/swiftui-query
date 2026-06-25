import SwiftUIQuery

// MARK: - User Queries

/// Fetches all users
struct UsersQuery: QueryKey {
    typealias Response = [User]

    var cacheKey: String { "users:all" }
    var tags: Set<QueryTag> { [.users] }
}

/// Fetches a single user by ID
struct UserQuery: QueryKey {
    typealias Response = User
    let userId: Int

    var cacheKey: String { "user:\(userId)" }
    var tags: Set<QueryTag> { [.users, .user(userId)] }
}

// MARK: - Post Queries

/// Fetches all posts
struct PostsQuery: QueryKey {
    typealias Response = [Post]

    var cacheKey: String { "posts:all" }
    var tags: Set<QueryTag> { [.posts] }
}

/// Fetches a single post by ID
struct PostQuery: QueryKey {
    typealias Response = Post
    let postId: Int

    var cacheKey: String { "post:\(postId)" }
    var tags: Set<QueryTag> { [.posts, .post(postId)] }
}

/// Fetches posts by a specific user
struct UserPostsQuery: QueryKey {
    typealias Response = [Post]
    let userId: Int

    var cacheKey: String { "user:\(userId):posts" }
    var tags: Set<QueryTag> { [.posts] }
}

// MARK: - Comment Queries

/// Fetches comments for a specific post
struct PostCommentsQuery: QueryKey {
    typealias Response = [Comment]
    let postId: Int

    var cacheKey: String { "post:\(postId):comments" }
    var tags: Set<QueryTag> { [.comments, .postComments(postId)] }
}
