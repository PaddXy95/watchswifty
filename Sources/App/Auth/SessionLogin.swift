import Vapor

extension Request {
    /// Signs `user` in on a new session ID. The session the request came with is deleted together with its data, so
    /// an ID planted in the browser beforehand (session fixation, e.g. a cookie set by another service on the same
    /// host) never becomes a signed-in session. `SessionsMiddleware` creates the new row and cookie.
    /// - Parameter user: The account to sign in.
    /// - Throws: Errors from deleting the old session row.
    func signInWithNewSession(_ user: User) async throws {
        if let old = session.id {
            try await application.sessions.driver.deleteSession(old, for: self).get()
        }
        session.id = nil
        session.data = SessionData()
        auth.login(user)
        session.authenticate(user)
    }
}
