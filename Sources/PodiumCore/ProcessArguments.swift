/// Resolves OCI image defaults and Podium process overrides into the argv the
/// runtime launches. Existing native `command`-only specs keep their historical
/// full-argv behavior; `entrypoint` or `args` opts into the split model.
public enum ProcessArguments {
    public static func resolve(
        imageEntrypoint: [String]?, imageCommand: [String]?,
        entrypoint: [String]?, command: [String]?, args: [String]?
    ) -> [String] {
        // Backward compatibility: Podium's original `command` field was the
        // complete argv, not OCI CMD. Applied specs rely on that behavior.
        if entrypoint == nil && args == nil {
            return command ?? (imageEntrypoint ?? []) + (imageCommand ?? [])
        }

        let selectedEntrypoint = entrypoint ?? imageEntrypoint ?? []
        let selectedCommand: [String]
        if let command {
            selectedCommand = command
        } else if entrypoint != nil {
            // Compose/OCI rule: overriding ENTRYPOINT without a command drops
            // the image CMD. An explicit empty entrypoint is meaningful too.
            selectedCommand = []
        } else {
            selectedCommand = imageCommand ?? []
        }
        return selectedEntrypoint + selectedCommand + (args ?? [])
    }
}
