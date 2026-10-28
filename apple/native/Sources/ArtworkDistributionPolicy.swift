// Public releases do not offer third-party cover downloads until distribution
// rights have been documented. User-imported images and existing local data
// remain separate from the catalog offered by VETA.
enum ArtworkDistributionPolicy {
    static var allowsRemoteCovers:Bool {
        #if VETA_JIT_DEVELOPMENT
        return true
        #else
        return false
        #endif
    }
}
