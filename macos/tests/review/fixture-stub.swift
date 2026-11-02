// CoreAPI.swift's mock-core half names Fixture; the review tests need none.
enum Fixture {
    case none
    var hasLog: Bool { false }
    func decisions() -> [Decision] { [] }
}
