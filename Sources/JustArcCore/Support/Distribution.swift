import Foundation

/// Which JustArc this is: the one downloaded from the website, or the one from the
/// Mac App Store. They are the same code, built twice.
///
/// The App Store build is made with `Scripts/build-app.sh … --app-store`, which
/// compiles with APP_STORE defined. It runs in the App Sandbox, updates only
/// through the App Store, and leaves out what the sandbox or the store's rules do
/// not allow: mounting disk images with hdiutil, and fetching and running RARLAB's
/// tool to write RAR. Code that must not be in that build at all, Sparkle and the
/// RAR download, is left out with `#if !APP_STORE`; everything else asks here.
public enum Distribution {
    #if APP_STORE
    public static let isAppStoreBuild = true
    #else
    public static let isAppStoreBuild = false
    #endif

    /// Whether this process runs in the App Sandbox, whatever it was built as. A
    /// second check, so that a sandboxed build never offers what would then fail.
    public static let isSandboxed =
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    private static var isRestricted: Bool { isAppStoreBuild || isSandboxed }

    /// Disk images are read by attaching them with hdiutil.
    public static var mountsDiskImages: Bool { !isRestricted }

    /// RAR is written by RARLAB's own tool, which JustArc downloads and runs.
    public static var writesRAR: Bool { !isRestricted }

    /// Checks for and installs its own updates, through Sparkle.
    public static var updatesItself: Bool { !isRestricted }
}
