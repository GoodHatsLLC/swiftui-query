import SwiftUI
import SwiftUIQuery

struct CreatePostView: View {
    let server: MockServer
    @Environment(\.dismiss) private var dismiss

    @Mutation private var createPost: MutationState<CreatePostInput, Post, Void>

    @State private var title = ""
    @State private var content = ""

    init(server: MockServer) {
        self.server = server
        self._createPost = Mutation(
            invalidates: .posts,
            mutationFn: { [server] input, _ in
                try await server.createPost(
                    title: input.title,
                    body: input.body,
                    authorId: input.authorId
                )
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("New Post") {
                    TextField("Title", text: $title)
                    TextField("Content", text: $content, axis: .vertical)
                        .lineLimit(5...10)
                }

                if let error = createPost.error {
                    Section {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Create Post")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        Task {
                            await submit()
                        }
                    }
                    .disabled(title.isEmpty || content.isEmpty || createPost.isPending)
                }
            }
            .overlay {
                if createPost.isPending {
                    ProgressView("Creating...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func submit() async {
        do {
            _ = try await createPost.mutate(
                CreatePostInput(title: title, body: content, authorId: 1)
            )
            dismiss()
        } catch {
            _ = error
        }
    }
}

struct AddCommentView: View {
    let postId: Int
    let server: MockServer

    @Environment(\.dismiss) private var dismiss

    @Mutation private var addComment: MutationState<CreateCommentInput, Comment, Void>

    @State private var commentBody = ""

    init(postId: Int, server: MockServer) {
        self.postId = postId
        self.server = server
        self._addComment = Mutation(
            invalidates: [QueryTag.postComments(postId)],
            mutationFn: { [server] input, _ in
                try await server.createComment(
                    postId: input.postId,
                    authorId: input.authorId,
                    body: input.body
                )
            }
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Add Comment") {
                    TextField("Your comment", text: $commentBody, axis: .vertical)
                        .lineLimit(3...6)
                }

                if let error = addComment.error {
                    Section {
                        Text(error.localizedDescription)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New Comment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        Task {
                            await submit()
                        }
                    }
                    .disabled(commentBody.isEmpty || addComment.isPending)
                }
            }
            .overlay {
                if addComment.isPending {
                    ProgressView("Submitting...")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func submit() async {
        do {
            _ = try await addComment.mutate(
                CreateCommentInput(postId: postId, authorId: 1, body: commentBody)
            )
            dismiss()
        } catch {
            _ = error
        }
    }
}
