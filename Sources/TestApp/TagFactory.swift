import SwiftUIQuery

extension QueryTag {
    public static let users: QueryTag = "users"
    public static let posts: QueryTag = "posts"
    public static let comments: QueryTag = "comments"

    public static func user(_ id: some CustomStringConvertible) -> QueryTag {
        QueryTag("users", String(describing: id))
    }

    public static func userPosts(_ userId: some CustomStringConvertible) -> QueryTag {
        QueryTag("users", String(describing: userId), "posts")
    }

    public static func post(_ id: some CustomStringConvertible) -> QueryTag {
        QueryTag("posts", String(describing: id))
    }

    public static func postComments(_ postId: some CustomStringConvertible) -> QueryTag {
        QueryTag("posts", String(describing: postId), "comments")
    }
}
