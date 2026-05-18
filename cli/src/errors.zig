pub const CliError = error{
    UserError,
    MissingArgument,
    InvalidArgument,
    InvalidReference,
    NotFound,
    AmbiguousReference,
    Unauthorized,
    InvalidEvent,
    LocalInboxChanged,
    GitFailed,
    ConfigNotFound,
    ConfigInvalid,
    NotGitRepository,
    SqliteFailed,
};

pub fn isUserError(err: anyerror) bool {
    return switch (err) {
        CliError.UserError,
        CliError.MissingArgument,
        CliError.InvalidArgument,
        CliError.InvalidReference,
        CliError.NotFound,
        CliError.AmbiguousReference,
        CliError.Unauthorized,
        CliError.InvalidEvent,
        CliError.LocalInboxChanged,
        CliError.NotGitRepository,
        => true,
        else => false,
    };
}

pub fn isReported(err: anyerror) bool {
    return isUserError(err) or switch (err) {
        CliError.GitFailed,
        CliError.SqliteFailed,
        => true,
        else => false,
    };
}
