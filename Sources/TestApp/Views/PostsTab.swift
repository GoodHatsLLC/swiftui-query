import SwiftUI
import SwiftUIQuery

struct PostsTab: View {
    var body: some View {
        NavigationStack {
            PostsListView()
                .navigationTitle("Posts")
        }
    }
}

struct PostsListView: View {
    @Environment(\.mockServer) private var server
    @State private var showingCreatePost = false


    @Query(PostsQuery(), fetch: { try await $0.mockServer.getPosts() }) var posts

    var body: some View {
            List {
                switch posts.state.result {
                case .idle:
                    Text("Initializing...")
                        .foregroundStyle(.secondary)

                case .loading:
                    ForEach(0..<5, id: \.self) { _ in
                        PostRowPlaceholder()
                    }

                case .success(let postList):
                    ForEach(postList) { post in
                        NavigationLink(value: post) {
                            PostRow(post: post)
                        }
                    }

                case .error(let error):
                    ErrorView(error: error) {
                        Task { await posts.refetch() }
                    }
                }
            }
            .navigationDestination(for: Post.self) { post in
                PostDetailView(postId: post.id)
            }
            .refreshable {
                await posts.refetch()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    HStack {
                        if posts.state.isFetching {
                            ProgressView()
                        }
                        Button {
                            showingCreatePost = true
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingCreatePost) {
                CreatePostView(server: server)
            }
    }
}

struct PostRow: View {
    let post: Post

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(post.title)
                .font(.headline)
                .lineLimit(2)

            Text(post.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                Label("\(post.likes)", systemImage: "heart.fill")
                    .font(.caption)
                    .foregroundStyle(.pink)

                Spacer()

                Text(post.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct PostRowPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(height: 20)

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 36)

            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 40, height: 14)
                Spacer()
            }
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
    }
}

struct PostDetailView: View {
    let postId: Int

    @Environment(\.mockServer) private var server
    @Environment(\.queryClient) private var client
    @State private var showingAddComment = false

    @Query private var post: QueryObserver<PostQuery>

    init(postId: Int) {
        self.postId = postId
        self._post = Query(PostQuery(postId: postId), fetch: { env in
            try await env.mockServer.getPost(id: postId)
        })
    }

    var body: some View {
        List {
            switch post.state.result {
            case .idle, .loading:
                Section {
                    PostDetailPlaceholder()
                }

            case .success(let postData):
                Section {
                    PostDetailContent(
                        post: postData,
                        onLike: { await handleLike() }
                    )
                }

                Section("Comments") {
                    CommentsSection(postId: postId)
                }

            case .error(let error):
                Section {
                    ErrorView(error: error) {
                        Task { await post.refetch() }
                    }
                }
            }
        }
        .navigationTitle("Post")
        .refreshable {
            await post.refetch()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAddComment = true
                } label: {
                    Image(systemName: "plus.bubble")
                }
            }
        }
        .sheet(isPresented: $showingAddComment) {
            AddCommentView(postId: postId, server: server)
        }
    }

    private func handleLike() async {
        // Optimistic update
        if var currentPost = post.state.data {
            currentPost.likes += 1
            await client.setQueryData(PostQuery(postId: postId), data: currentPost)
        }

        do {
            let updatedPost = try await server.likePost(id: postId)
            await client.setQueryData(PostQuery(postId: postId), data: updatedPost)
        } catch {
            // Revert on error by refetching
            await post.refetch()
        }
    }
}

struct CommentsSection: View {
    let postId: Int

    @Query private var comments: QueryObserver<PostCommentsQuery>

    init(postId: Int) {
        self.postId = postId
        self._comments = Query(PostCommentsQuery(postId: postId), fetch: { env in
            try await env.mockServer.getPostComments(postId: postId)
        })
    }

    var body: some View {
        CommentsList(commentsState: comments.state)
            .refreshable {
                await comments.refetch()
            }
    }
}

struct PostDetailContent: View {
    let post: Post
    let onLike: () async -> Void

    @State private var isLiking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(post.title)
                .font(.title2)
                .fontWeight(.bold)

            Text(post.body)
                .font(.body)

            HStack {
                Button {
                    Task {
                        isLiking = true
                        await onLike()
                        isLiking = false
                    }
                } label: {
                    Label("\(post.likes)", systemImage: "heart.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .tint(.pink)
                .disabled(isLiking)

                Spacer()

                Text(post.createdAt.formatted(date: .long, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 8)
    }
}

struct PostDetailPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.3))
                .frame(height: 28)

            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 80)

            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 60, height: 32)
                Spacer()
            }
        }
        .padding(.vertical, 8)
        .redacted(reason: .placeholder)
    }
}

struct CommentsList: View {
    let commentsState: QueryState<[Comment]>

    var body: some View {
        switch commentsState.result {
        case .idle, .loading:
            ForEach(0..<3, id: \.self) { _ in
                CommentRowPlaceholder()
            }

        case .success(let commentList):
            if commentList.isEmpty {
                Text("No comments yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(commentList) { comment in
                    CommentRow(comment: comment)
                }
            }

        case .error(let error):
            Text("Failed to load comments: \(error.localizedDescription)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}

struct CommentRow: View {
    let comment: Comment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(comment.body)
                .font(.body)

            Text(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct CommentRowPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 40)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.gray.opacity(0.15))
                .frame(width: 100, height: 12)
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
    }
}
