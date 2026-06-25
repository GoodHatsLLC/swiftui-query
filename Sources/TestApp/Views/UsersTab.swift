import SwiftUI
import SwiftUIQuery

struct UsersTab: View {
    var body: some View {
        NavigationStack {
            UserListView()
                .navigationTitle("Users")
        }
    }
}

struct UserListView: View {
    @Environment(\.mockServer) private var server
    @Query(UsersQuery(), fetch: { try await $0.mockServer.getUsers() }) var users
    var body: some View {
            List {
                switch users.result {
                case .idle:
                    Text("Initializing...")
                        .foregroundStyle(.secondary)

                case .loading:
                    ForEach(0..<3, id: \.self) { _ in
                        UserRowPlaceholder()
                    }

                case .success(let userList):
                    ForEach(userList) { user in
                        NavigationLink(value: user) {
                            UserRow(user: user)
                        }
                    }

                case .error(let error):
                    ErrorView(error: error) {
                        Task { _ = try? await $users.refetch() }
                    }
                }
            }
            .navigationDestination(for: User.self) { user in
                UserDetailView(userId: user.id)
            }
            .refreshable {
                _ = try? await $users.refetch()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if users.isFetching {
                        ProgressView()
                    }
                }
            }
    }
}

struct UserRow: View {
    let user: User

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: user.avatarUrl)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(Color.gray.opacity(0.3))
            }
            .frame(width: 44, height: 44)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                    .font(.headline)
                Text(user.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

struct UserRowPlaceholder: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 120, height: 16)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 160, height: 12)
            }
        }
        .padding(.vertical, 4)
        .redacted(reason: .placeholder)
    }
}

struct UserDetailView: View {
    let userId: Int

    @Query<UserQuery> private var user: QueryState<User>

    init(userId: Int) {
        self.userId = userId
        self._user = Query(UserQuery(userId: userId), fetch: { env in
            try await env.mockServer.getUser(id: userId)
        })
    }

    var body: some View {
        List {
            switch user.result {
            case .idle, .loading:
                Section {
                    UserDetailPlaceholder()
                }

            case .success(let userData):
                Section {
                    UserDetailHeader(user: userData)
                }

                Section("Posts") {
                    UserPostsSection(userId: userId)
                }

            case .error(let error):
                Section {
                    ErrorView(error: error) {
                        Task { _ = try? await $user.refetch() }
                    }
                }
            }
        }
        .navigationTitle(user.data?.name ?? "User")
        .refreshable {
            _ = try? await $user.refetch()
        }
    }
}

struct UserPostsSection: View {
    let userId: Int

    @Query<UserPostsQuery> private var userPosts: QueryState<[Post]>

    init(userId: Int) {
        self.userId = userId
        self._userPosts = Query(UserPostsQuery(userId: userId), fetch: { env in
            try await env.mockServer.getUserPosts(userId: userId)
        })
    }

    var body: some View {
        UserPostsList(postsState: userPosts)
            .refreshable {
                _ = try? await $userPosts.refetch()
            }
    }
}

struct UserDetailHeader: View {
    let user: User

    var body: some View {
        VStack(spacing: 16) {
            AsyncImage(url: URL(string: user.avatarUrl)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Circle()
                    .fill(Color.gray.opacity(0.3))
            }
            .frame(width: 100, height: 100)
            .clipShape(Circle())

            VStack(spacing: 4) {
                Text(user.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(user.email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !user.bio.isEmpty {
                Text(user.bio)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text("Joined \(user.createdAt.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct UserDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 100, height: 100)

            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 150, height: 24)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 200, height: 16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .redacted(reason: .placeholder)
    }
}

struct UserPostsList: View {
    let postsState: QueryState<[Post]>

    var body: some View {
        switch postsState.result {
        case .idle, .loading:
            ForEach(0..<2, id: \.self) { _ in
                PostRowPlaceholder()
            }

        case .success(let posts):
            if posts.isEmpty {
                Text("No posts yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(posts) { post in
                    NavigationLink(value: post) {
                        PostRow(post: post)
                    }
                }
            }

        case .error(let error):
            Text("Failed to load posts: \(error.localizedDescription)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
